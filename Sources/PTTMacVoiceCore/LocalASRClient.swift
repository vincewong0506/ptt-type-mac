import Foundation
import AVFoundation
import AudioCommon
import Qwen3ASR

struct ASRTranscriptResponse {
    let text: String
    let language: String?
}

actor LocalASRClient {
    // Encoder hard limit: maxSourcePositions(1500) × downsample(8) × 10ms/frame
    // = 120s. Past this the encoder silently truncates or runs out of
    // positional embedding range. Reject early with a clear error instead.
    static let maxAudioSeconds: Double = 120
    static let sampleRate: Int = 16000

    static let defaultPrompt = """
        说话人是软件工程师，使用普通话与英文技术术语混杂表达。识别时保持英文原样、不要音译（如 Pod、API、Swift）。数字使用阿拉伯数字（如 1000、下午 3 点）。
        """

    var prompt: String = LocalASRClient.defaultPrompt
    var language: String? = nil
    // The active variant repo id, chosen by AppModel from the persisted
    // ModelVariant. We default to the 1.7B 8-bit variant to match the
    // pre-refactor behavior on first launch — AppModel overwrites this via
    // setModelId before any load/transcribe happens.
    var modelId: String = ModelVariant.default.rawValue
    // Where weights come from on a fresh download. AppModel pushes the
    // persisted DownloadSource at startup. Only matters when the cache is
    // empty — once files are on disk we always load offline.
    var downloadSource: DownloadSource = .default

    // Headroom for long PTT clips. 448 (the upstream default) caps decoder
    // output around 1–2min of normal speech; 1024 covers the full 120s
    // encoder window with margin.
    var maxOutputTokens: Int = 1024

    // Autoregressive decoders can fall into repeat loops on long clips, more
    // so under quantization. 1.1 + n-gram=3 is the documented defensive
    // setting; harmless at 8-bit, useful insurance.
    var repetitionPenalty: Float = 1.1
    var noRepeatNgramSize: Int = 3

    // Greedy. Voice-coding wants determinism, no sampling randomness.
    var temperature: Float = 0.0

    private var model: Qwen3ASRModel?
    private var loadingTask: Task<Qwen3ASRModel, Error>?

    func setPrompt(_ value: String) { self.prompt = value }
    func setLanguage(_ value: String?) { self.language = value }

    // When the active variant changes, the cached Qwen3ASRModel and any
    // in-flight load Task are for the OLD modelId — drop them so the next
    // ensureModel pass loads weights from the new repo's cache directory.
    func setModelId(_ value: String) {
        guard value != modelId else { return }
        modelId = value
        model = nil
        loadingTask?.cancel()
        loadingTask = nil
    }

    // Source only matters for new downloads — leave the loaded `model`
    // alone (those weights are bit-identical regardless of source) but
    // cancel any in-flight download Task that's pulling from the old
    // source so the next ensureModel pass picks up the new choice.
    func setDownloadSource(_ value: DownloadSource) {
        guard value != downloadSource else { return }
        downloadSource = value
        loadingTask?.cancel()
        loadingTask = nil
    }

    func loadModel(progressHandler: ((Double, String) -> Void)? = nil) async throws {
        _ = try await ensureModel(allowDownload: true, progressHandler: progressHandler)
    }

    func transcribe(wavURL: URL) async throws -> ASRTranscriptResponse {
        let samples = try Self.readWAVAsFloats(url: wavURL)
        return try await transcribe(samples: samples)
    }

    func transcribePCM16(_ pcm16: Data) async throws -> ASRTranscriptResponse {
        let samples = Self.pcm16ToFloats(pcm16)
        return try await transcribe(samples: samples)
    }

    // `allowDownload: false` is the transcribe path's safety belt — it lets
    // an in-flight load Task (started by an explicit user-authorized
    // `loadModel` call) finish, but refuses to KICK OFF a fresh download
    // implicitly. Prevents "press PTT and silently pull 2.5 GB" surprises.
    private func ensureModel(
        allowDownload: Bool,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> Qwen3ASRModel {
        if let model { return model }
        if let task = loadingTask { return try await task.value }

        let id = modelId
        let source = downloadSource
        // Skip the HuggingFace metadata round-trip when every required file
        // is already on disk. Without this, each app launch re-validates
        // against HF and a flaky network can fail mid-stream (NSURLErrorDomain
        // -1005). The user can force a re-download by deleting the cache
        // directory.
        var offline = Self.cachedFilesComplete(for: id)
        if !allowDownload && !offline {
            throw ASRError.modelNotReady
        }
        let task = Task {
            // ModelScope path: download files into the same cache dir
            // speech-swift looks at, then call fromPretrained with
            // offlineMode:true so HubApi never validates against HF
            // (it would fail — no .metadata sidecars in our payload).
            if source == .modelScope, !offline {
                let dir = try HuggingFaceDownloader.getCacheDirectory(for: id)
                try await ModelScopeDownloader.download(
                    modelId: id,
                    to: dir,
                    progressHandler: progressHandler
                )
                offline = Self.cachedFilesComplete(for: id)
            }
            return try await Qwen3ASRModel.fromPretrained(
                modelId: id,
                offlineMode: offline,
                progressHandler: progressHandler
            )
        }
        loadingTask = task
        do {
            let loaded = try await task.value
            self.model = loaded
            self.loadingTask = nil
            return loaded
        } catch {
            self.loadingTask = nil
            throw error
        }
    }

    /// Returns true if every file Qwen3ASR loads (safetensors + tokenizer +
    /// config) already exists in the model's cache directory. Mirrors the
    /// `additionalFiles` list passed to `HuggingFaceDownloader.downloadWeights`
    /// inside `Qwen3ASRModel.fromPretrained`.
    nonisolated public static func cachedFilesComplete(for modelId: String) -> Bool {
        guard let dir = try? HuggingFaceDownloader.getCacheDirectory(for: modelId) else {
            return false
        }
        let fm = FileManager.default
        guard HuggingFaceDownloader.weightsExist(in: dir) else { return false }
        let required = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]
        return required.allSatisfy {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Cache directory used by HuggingFaceDownloader for a given modelId.
    /// Exposed for cache-size walking and Show-in-Finder UI.
    nonisolated public static func cacheDirectory(for modelId: String) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: modelId)
    }

    /// Total bytes used on disk by the cache directory for a given modelId.
    /// Returns 0 if the directory doesn't exist or can't be enumerated.
    nonisolated public static func cacheSizeOnDisk(for modelId: String) -> Int64 {
        guard let dir = try? HuggingFaceDownloader.getCacheDirectory(for: modelId) else {
            return 0
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            if let alloc = values?.totalFileAllocatedSize {
                total += Int64(alloc)
            } else if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func transcribe(samples: [Float]) async throws -> ASRTranscriptResponse {
        guard !samples.isEmpty else {
            return ASRTranscriptResponse(text: "", language: language)
        }
        let durationSeconds = Double(samples.count) / Double(Self.sampleRate)
        guard durationSeconds <= Self.maxAudioSeconds else {
            throw ASRError.audioTooLong(
                seconds: durationSeconds,
                limit: Self.maxAudioSeconds
            )
        }
        let model = try await ensureModel(allowDownload: false)
        let options = Qwen3DecodingOptions(
            maxTokens: maxOutputTokens,
            language: language,
            context: prompt.isEmpty ? nil : prompt,
            repetitionPenalty: repetitionPenalty,
            noRepeatNgramSize: noRepeatNgramSize,
            temperature: temperature
        )
        let text = model.transcribe(audio: samples, sampleRate: Self.sampleRate, options: options)
        return ASRTranscriptResponse(text: text, language: language)
    }

    private static func pcm16ToFloats(_ data: Data) -> [Float] {
        let usable = data.count - (data.count % 2)
        guard usable > 0 else { return [] }
        return data.prefix(usable).withUnsafeBytes { raw -> [Float] in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            return int16Buffer.map { Float(Int16(littleEndian: $0)) / 32768.0 }
        }
    }

    private static func readWAVAsFloats(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw ASRError.invalidWAV
        }
        try file.read(into: buffer)
        guard let floatPtr = buffer.floatChannelData else {
            throw ASRError.invalidWAV
        }
        return Array(UnsafeBufferPointer(start: floatPtr[0], count: Int(buffer.frameLength)))
    }
}

enum ASRError: LocalizedError {
    case invalidWAV
    case modelNotReady
    case audioTooLong(seconds: Double, limit: Double)

    var errorDescription: String? {
        switch self {
        case .invalidWAV:
            return "Could not read WAV file as audio"
        case .modelNotReady:
            return "ASR model is not ready"
        case .audioTooLong(let seconds, let limit):
            return String(
                format: "Audio is %.1fs, exceeds the %.0fs encoder window — split this clip into shorter PTT presses",
                seconds,
                limit
            )
        }
    }
}
