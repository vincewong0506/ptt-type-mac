import Foundation

struct WAVFileInfo: Equatable {
    let url: URL
    let pcmByteCount: UInt32
    let sampleRate: UInt32
    let channels: UInt16
    let bitsPerSample: UInt16

    var duration: TimeInterval {
        let bytesPerSecond = Double(sampleRate) * Double(channels) * Double(bitsPerSample / 8)
        guard bytesPerSecond > 0 else { return 0 }
        return Double(pcmByteCount) / bytesPerSecond
    }

    var fileByteCount: UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }
}

final class WAVFileRecorder {
    static let defaultURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return documents
            .appendingPathComponent("PTTMacVoice", isDirectory: true)
            .appendingPathComponent("last-ptt.wav")
    }()

    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16
    private var fileHandle: FileHandle?
    private(set) var url: URL
    private(set) var pcmByteCount: UInt32 = 0

    init(url: URL = WAVFileRecorder.defaultURL, sampleRate: UInt32 = 16_000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    func start() throws {
        finish()

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        fileHandle = handle
        pcmByteCount = 0
        try handle.write(contentsOf: header(dataByteCount: 0))
    }

    func appendPCM16(_ data: Data) throws {
        guard let fileHandle else { return }
        try fileHandle.write(contentsOf: data)
        pcmByteCount &+= UInt32(data.count)
    }

    func finish() {
        guard let fileHandle else { return }
        do {
            try fileHandle.seek(toOffset: 0)
            try fileHandle.write(contentsOf: header(dataByteCount: pcmByteCount))
            try fileHandle.close()
        } catch {
            try? fileHandle.close()
        }
        self.fileHandle = nil
    }

    func currentInfo() -> WAVFileInfo? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return WAVFileInfo(
            url: url,
            pcmByteCount: pcmByteCount,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
    }

    private func header(dataByteCount: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLE32(36 &+ dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE32(16)
        data.appendLE16(1)
        data.appendLE16(channels)
        data.appendLE32(sampleRate)
        data.appendLE32(byteRate)
        data.appendLE16(blockAlign)
        data.appendLE16(bitsPerSample)
        data.appendASCII("data")
        data.appendLE32(dataByteCount)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
