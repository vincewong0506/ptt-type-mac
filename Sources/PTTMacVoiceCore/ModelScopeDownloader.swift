import Foundation
import AudioCommon

// Sidecar downloader for ModelScope (魔搭). Speech-swift's
// HuggingFaceDownloader is hard-coded to HF protocol via swift-transformers
// HubApi; ModelScope speaks a different REST shape, so we do the network
// work ourselves and drop the files into the same on-disk cache directory
// (HuggingFaceDownloader.getCacheDirectory). After this completes, the
// caller invokes Qwen3ASRModel.fromPretrained with offlineMode:true and
// HubApi never touches the network — the path is `offlineMode &&
// weightsExist` short-circuits inside speech-swift.
//
// Per-file atomicity: we stream into <name>.partial and rename on success.
// Strict completeness: after every file finishes, we re-verify each
// expected entry exists at its declared size. weightsExist alone would say
// "ready" on a partial multi-shard download because it only checks for ANY
// .safetensors file.
public enum ModelScopeDownloader {
    public enum Error: Swift.Error, LocalizedError {
        case listFailed(modelId: String, status: Int)
        case decodeFailed(String)
        case downloadFailed(file: String, status: Int)
        case incomplete(missing: [String])
        case unsafeFileName(String)

        public var errorDescription: String? {
            switch self {
            case .listFailed(let id, let s):
                return "ModelScope listing failed for \(id) (HTTP \(s))"
            case .decodeFailed(let m):
                return "ModelScope response decode failed: \(m)"
            case .downloadFailed(let f, let s):
                return "ModelScope download failed for \(f) (HTTP \(s))"
            case .incomplete(let missing):
                return "ModelScope download incomplete; missing or wrong size: \(missing.joined(separator: ", "))"
            case .unsafeFileName(let f):
                return "Refusing unsafe ModelScope file name: \(f)"
            }
        }
    }

    private static let host = "https://modelscope.cn"
    private static let userAgent = "PTTVoice/1.0"
    private static let chunkSize = 256 * 1024
    private static let requiredTokenizerFiles: Set<String> = [
        "config.json", "vocab.json", "merges.txt", "tokenizer_config.json"
    ]

    public static func download(
        modelId: String,
        to directory: URL,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        progressHandler?(0.0, "Listing ModelScope files…")
        let allFiles = try await fetchFileList(modelId: modelId)

        // Filter to what speech-swift expects: weights + tokenizer/config.
        // Includes `model.safetensors.index.json` for sharded weights.
        let required = allFiles.filter { entry in
            let p = entry.path.lowercased()
            if p.hasSuffix(".safetensors") { return true }
            if entry.path == "model.safetensors.index.json" { return true }
            return requiredTokenizerFiles.contains(entry.path)
        }

        guard !required.isEmpty else {
            throw Error.incomplete(missing: ["<no required files in repo listing>"])
        }

        let totalBytes = max(1, required.map(\.size).reduce(0, +))
        let progress = ByteProgress()

        for entry in required {
            try Task.checkCancellation()

            // Validate the basename. These repos are flat — if a future
            // entry includes a subdir, refuse rather than silently flatten.
            let safeName: String
            do {
                safeName = try HuggingFaceDownloader.validatedRemoteFileName(entry.path)
            } catch {
                throw Error.unsafeFileName(entry.path)
            }

            let dest = directory.appendingPathComponent(safeName, isDirectory: false)

            // Resume hint: if a previous run already finished this file at
            // the expected size, skip the network round-trip entirely.
            if fileMatchesExpectedSize(at: dest, expected: entry.size) {
                progress.add(entry.size)
                let frac = Double(progress.value) / Double(totalBytes)
                progressHandler?(min(frac, 0.999), "Cached \(safeName)")
                continue
            }

            try await streamDownload(
                modelId: modelId,
                filePath: entry.path,
                expectedSize: entry.size,
                to: dest,
                progress: progress,
                totalBytes: totalBytes,
                progressHandler: progressHandler
            )
        }

        // Strict completeness — every required entry must exist at its
        // declared size on disk. weightsExist alone would falsely succeed
        // on a partial multi-shard download.
        var missing: [String] = []
        for entry in required {
            let path = directory.appendingPathComponent(entry.path, isDirectory: false)
            if !fileMatchesExpectedSize(at: path, expected: entry.size) {
                missing.append(entry.path)
            }
        }
        if !missing.isEmpty {
            throw Error.incomplete(missing: missing)
        }

        progressHandler?(1.0, "Download complete")
    }

    // MARK: - Helpers

    private struct FileEntry {
        let path: String
        let size: Int64
    }

    private static func fetchFileList(modelId: String) async throws -> [FileEntry] {
        var components = URLComponents(string: "\(host)/api/v1/models/\(modelId)/repo/files")!
        components.queryItems = [
            URLQueryItem(name: "Revision", value: "master"),
            URLQueryItem(name: "Root", value: "")
        ]
        guard let url = components.url else {
            throw Error.listFailed(modelId: modelId, status: 0)
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw Error.listFailed(modelId: modelId, status: code)
        }
        // ModelScope returns PascalCase keys: { Code, Data: { Files: [{ Path, Size, ... }] } }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["Data"] as? [String: Any],
              let filesArr = dataDict["Files"] as? [[String: Any]]
        else {
            throw Error.decodeFailed("unexpected JSON shape from \(url.absoluteString)")
        }
        var entries: [FileEntry] = []
        for f in filesArr {
            guard let path = f["Path"] as? String else { continue }
            let size = (f["Size"] as? NSNumber)?.int64Value ?? 0
            entries.append(FileEntry(path: path, size: size))
        }
        return entries
    }

    private static func streamDownload(
        modelId: String,
        filePath: String,
        expectedSize: Int64,
        to dest: URL,
        progress: ByteProgress,
        totalBytes: Int64,
        progressHandler: ((Double, String) -> Void)?
    ) async throws {
        var components = URLComponents(string: "\(host)/api/v1/models/\(modelId)/repo")!
        components.queryItems = [
            URLQueryItem(name: "Revision", value: "master"),
            URLQueryItem(name: "FilePath", value: filePath)
        ]
        guard let url = components.url else {
            throw Error.downloadFailed(file: filePath, status: 0)
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let fm = FileManager.default
        let partial = dest.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw Error.downloadFailed(file: filePath, status: -1)
        }
        let handle = try FileHandle(forWritingTo: partial)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            try? handle.close()
            try? fm.removeItem(at: partial)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw Error.downloadFailed(file: filePath, status: code)
        }

        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var lastReportedAt = Date.distantPast

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= chunkSize {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    progress.add(Int64(buffer.count))
                    buffer.removeAll(keepingCapacity: true)

                    let now = Date()
                    if now.timeIntervalSince(lastReportedAt) >= 0.2 {
                        let frac = Double(progress.value) / Double(totalBytes)
                        progressHandler?(min(frac, 0.999), "Downloading \(filePath)")
                        lastReportedAt = now
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                progress.add(Int64(buffer.count))
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: partial)
            throw error
        }

        // Atomic rename. If the final path already exists from a previous
        // partial run, replace it.
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: partial, to: dest)

        // Verify the on-disk size matches what ModelScope advertised. We
        // don't throw here — the strict-completeness pass at the end will
        // collect ALL mismatches into one error so the user sees what's
        // wrong end-to-end. But we DO log when expectedSize is suspect (0).
        if expectedSize > 0,
           let attrs = try? fm.attributesOfItem(atPath: dest.path),
           let actual = (attrs[.size] as? NSNumber)?.int64Value,
           actual != expectedSize {
            // Fall through; the completeness pass will catch this.
        }

        let frac = Double(progress.value) / Double(totalBytes)
        progressHandler?(min(frac, 0.999), "Downloaded \(filePath)")
    }

    private static func fileMatchesExpectedSize(at url: URL, expected: Int64) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let actual = (attrs[.size] as? NSNumber)?.int64Value
        else {
            return false
        }
        // expected can be 0 if ModelScope didn't report a size; treat that
        // as "any non-empty file is fine" so we don't reject unexpectedly.
        if expected == 0 { return actual > 0 }
        return actual == expected
    }

    // Atomic accumulator so the per-file streaming loops can update one
    // shared byte counter that the aggregate progress fraction reads from.
    private final class ByteProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int64 = 0
        var value: Int64 {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func add(_ delta: Int64) {
            lock.lock()
            _value += delta
            lock.unlock()
        }
    }
}
