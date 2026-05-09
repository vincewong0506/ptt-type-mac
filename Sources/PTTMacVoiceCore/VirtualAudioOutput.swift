import Foundation
import AudioToolbox
import CoreAudio

final class VirtualAudioOutput {
    private let sampleRate: Double = 16_000
    private let channels: UInt32 = 1
    private let framesPerBuffer = 320

    private var queue: AudioQueueRef?
    private var pendingPCM = Data()
    private let lock = NSLock()

    func start(deviceID: AudioDeviceID) throws {
        stop()

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var newQueue: AudioQueueRef?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioQueueNewOutput(&format, outputCallback, selfPointer, nil, nil, 0, &newQueue), "AudioQueueNewOutput")
        guard let newQueue else { throw AudioOutputError.queueCreationFailed }

        if let uid = AudioDeviceManager.deviceUID(id: deviceID) {
            var deviceUID = uid as CFString
            try check(AudioQueueSetProperty(newQueue, kAudioQueueProperty_CurrentDevice, &deviceUID, UInt32(MemoryLayout<CFString>.size)), "AudioQueueSetProperty(CurrentDevice)")
        }

        queue = newQueue

        for _ in 0..<3 {
            try enqueueSilenceBuffer()
        }
        try check(AudioQueueStart(newQueue, nil), "AudioQueueStart")
    }

    func stop() {
        guard let queue else { return }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        self.queue = nil
        lock.withLock {
            pendingPCM.removeAll(keepingCapacity: true)
        }
    }

    func enqueuePCM16(_ data: Data) {
        lock.withLock {
            pendingPCM.append(data)
            let maxBufferedBytes = Int(sampleRate) * 2
            if pendingPCM.count > maxBufferedBytes {
                pendingPCM.removeFirst(pendingPCM.count - maxBufferedBytes)
            }
        }
    }

    fileprivate func fill(_ buffer: AudioQueueBufferRef) {
        let requestedBytes = framesPerBuffer * 2
        var chunk = Data()
        lock.withLock {
            let byteCount = min(requestedBytes, pendingPCM.count)
            if byteCount > 0 {
                chunk = pendingPCM.prefix(byteCount)
                pendingPCM.removeFirst(byteCount)
            }
        }

        buffer.pointee.mAudioDataByteSize = UInt32(requestedBytes)
        memset(buffer.pointee.mAudioData, 0, requestedBytes)
        if !chunk.isEmpty {
            _ = chunk.withUnsafeBytes { rawBuffer in
                memcpy(buffer.pointee.mAudioData, rawBuffer.baseAddress, chunk.count)
            }
        }
    }

    private func enqueueSilenceBuffer() throws {
        guard let queue else { return }
        var buffer: AudioQueueBufferRef?
        try check(AudioQueueAllocateBuffer(queue, UInt32(framesPerBuffer * 2), &buffer), "AudioQueueAllocateBuffer")
        guard let buffer else { return }
        fill(buffer)
        try check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), "AudioQueueEnqueueBuffer")
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioOutputError.operationFailed(operation, status) }
    }
}

private let outputCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData else { return }
    let output = Unmanaged<VirtualAudioOutput>.fromOpaque(userData).takeUnretainedValue()
    output.fill(buffer)
    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
}

enum AudioOutputError: LocalizedError {
    case queueCreationFailed
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .queueCreationFailed:
            return "Could not create audio queue"
        case .operationFailed(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
