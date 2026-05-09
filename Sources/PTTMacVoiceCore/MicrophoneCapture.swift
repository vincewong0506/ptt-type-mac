import Foundation
import AVFoundation
import CoreAudio
import OSLog

// Wraps AVAudioEngine to deliver 16 kHz mono PCM16 chunks compatible with
// LocalASRClient.transcribePCM16, WAVFileRecorder.appendPCM16, and
// AppModel.appendWaveformLevel — the same contract the BLE / SBC path
// produces so AppModel can route either source through identical handlers.
//
// The Mac's input device usually delivers 44.1 kHz or 48 kHz Float32 stereo,
// so we install an AVAudioConverter to resample + mix down to mono Float32
// at 16 kHz, then pack to Int16 LE manually (AVAudioConverter doesn't switch
// bit depth in one pass cleanly).
//
// **Buffer ownership**: this class owns the authoritative accumulated PCM
// under `bufferLock`. `stop()` returns the complete buffer atomically — that
// avoids a race where late tap callbacks dispatched to MainActor could
// arrive *after* AppModel has already snapshotted its own copy and started
// transcribing. `onPCMChunk` is still called per-chunk for live UI side
// effects (waveform, optional WAV writing) but is NOT the source of truth
// for the ASR input.
final class MicrophoneCapture {
    /// One row in the user-facing input-device picker.
    struct InputDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        let deviceID: AudioDeviceID
        var id: String { uid }
    }

    enum CaptureError: Error, LocalizedError {
        case permissionDenied
        case permissionUndetermined
        case noInputDevice
        case engineStartFailed(Error)
        case converterCreateFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access denied — grant in System Settings → Privacy & Security."
            case .permissionUndetermined:
                return "Microphone access has not been requested yet."
            case .noInputDevice:
                return "No audio input device available."
            case .engineStartFailed(let underlying):
                return "AudioEngine failed to start: \(underlying.localizedDescription)"
            case .converterCreateFailed:
                return "Failed to create audio format converter."
            }
        }
    }

    static let targetSampleRate: Double = 16_000
    static let targetChannelCount: AVAudioChannelCount = 1
    // ~100 ms native chunks before resampling — small enough for snappy
    // waveform updates, large enough to keep tap callback overhead low.
    private static let nativeTapBufferSize: AVAudioFrameCount = 4800

    /// Fires off the audio render thread with one PCM16-LE mono 16 kHz chunk.
    /// Used by AppModel for live waveform updates and WAV writing — NOT for
    /// PCM accumulation (the authoritative buffer lives in this class).
    var onPCMChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var isCapturing = false
    private let logger = Logger(subsystem: "com.pttcoding.PTTVoice", category: "Mic")

    /// User-pinned input device UID. nil means follow the system default
    /// at every PTT press (the original behavior). AppModel writes this
    /// from its persisted setting via `setPreferredDeviceUID(_:)`. Only
    /// read at start() time, so changing it mid-session is harmless.
    var preferredDeviceUID: String?

    // Authoritative PCM accumulator. Written from the audio render thread
    // inside `handle(buffer:)` and read on the main actor at stop()/snapshot().
    private let bufferLock = NSLock()
    private var collectedBuffer = Data()

    // Diagnostic counter — log RMS of the first few chunks per session so
    // a "data flowed but it was silent" failure mode is debuggable from
    // the log alone (we don't otherwise see what the audio level was).
    private var diagnosticChunkCount = 0
    private static let diagnosticChunkLimit = 3

    init() {
        // Target: Float32 mono 16 kHz, non-interleaved (interleaved is moot
        // for mono). We hand this to AVAudioConverter; the float-to-Int16
        // pack happens after.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        ) else {
            fatalError("Failed to construct target AVAudioFormat — should be impossible.")
        }
        self.targetFormat = format
    }

    static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// macOS will show the system permission prompt the first time this is
    /// called for the binary. Subsequent calls return the cached decision.
    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        guard !isCapturing else { return }

        switch Self.permissionStatus {
        case .denied, .restricted:
            throw CaptureError.permissionDenied
        case .notDetermined:
            throw CaptureError.permissionUndetermined
        case .authorized:
            break
        @unknown default:
            throw CaptureError.permissionDenied
        }

        let input = engine.inputNode

        // CRITICAL on macOS: AVAudioEngine.inputNode does NOT auto-bind to
        // any input device. Without an explicit AudioUnit device set, the
        // engine happily fires tap callbacks but the buffers are
        // zero-filled — known macOS gotcha that bites everyone porting an
        // iOS pattern over. Honors `preferredDeviceUID` if set & resolvable;
        // otherwise falls back to the system default.
        try Self.bindInputDevice(
            to: input,
            preferredUID: preferredDeviceUID,
            logger: logger
        )

        // outputFormat, NOT inputFormat. On macOS, inputFormat reports the
        // hardware-side format which is often different from what the engine
        // actually delivers to a tap (the engine has its own internal
        // converter sitting between the hardware and the node graph).
        let nativeFormat = input.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw CaptureError.converterCreateFailed
        }
        self.converter = converter

        bufferLock.lock()
        collectedBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        diagnosticChunkCount = 0

        input.installTap(
            onBus: 0,
            bufferSize: Self.nativeTapBufferSize,
            format: nativeFormat
        ) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        // NOTE: an earlier iteration also did `engine.connect(input, to:
        // engine.mainMixerNode)` to coerce the engine into pulling from
        // the input. With the explicit AudioUnit device binding above,
        // that's not needed — and it actively breaks engine init with
        // -10875 because mainMixer auto-connects to outputNode (speakers)
        // and the input mic's format is rejected by the speaker's HW
        // format validation. Tap alone is fine once the device is bound.

        engine.prepare()
        do {
            try engine.start()
            isCapturing = true
            logger.info("Mic engine started: native \(nativeFormat.sampleRate, privacy: .public) Hz, \(nativeFormat.channelCount, privacy: .public) ch -> 16 kHz mono")
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw CaptureError.engineStartFailed(error)
        }
    }

    /// Stop the engine and return everything captured since `start()`. The
    /// internal buffer is cleared as part of the call, so consecutive
    /// stop()s return empty Data.
    @discardableResult
    func stop() -> Data {
        guard isCapturing else { return Data() }
        // removeTap() blocks until any in-flight tap callback finishes,
        // so by the time we read collectedBuffer below it includes every
        // sample the engine has produced.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isCapturing = false

        bufferLock.lock()
        let result = collectedBuffer
        collectedBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        return result
    }

    /// Peek at the buffer without resetting. Used by AppModel at `.commit`
    /// time to backfill the WAV file with audio captured during the
    /// pre-grace `.tentative` window.
    func snapshot() -> Data {
        bufferLock.lock()
        let copy = collectedBuffer
        bufferLock.unlock()
        return copy
    }

    // MARK: - Tap handler

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Diagnostic: peek at the native input level for the first few
        // chunks. If this is ~0 we know the engine isn't actually getting
        // mic data; if it's >0 but the converted output is silent, the
        // converter setup is wrong.
        if diagnosticChunkCount < Self.diagnosticChunkLimit {
            let nativeRMS = nativeBufferRMS(buffer)
            logger.info("Mic chunk \(self.diagnosticChunkCount, privacy: .public): native frames=\(buffer.frameLength, privacy: .public) ch=\(buffer.format.channelCount, privacy: .public) interleaved=\(buffer.format.isInterleaved, privacy: .public) RMS=\(nativeRMS, privacy: .public)")
        }

        // Output capacity: input frames × (target rate / source rate), with
        // a 1-frame headroom for round-off.
        let outputCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * Self.targetSampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { return }

        var inputProvided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusOut in
            // Hand the input buffer exactly once per convert() call, then
            // tell the converter "no more right now" — NOT endOfStream.
            // .endOfStream is a stream-termination signal: it tears down
            // the resampler's internal filter state, so subsequent
            // convert() calls on the same instance silently return zero
            // output. That bug only shows up after the first chunk; the
            // first one converts fine, every subsequent one is dropped,
            // which exactly matches the "captured 100 ms regardless of
            // hold duration" symptom we saw in the logs.
            if inputProvided {
                statusOut.pointee = .noDataNow
                return nil
            }
            inputProvided = true
            statusOut.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let error {
                logger.error("Conversion error: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let frames = Int(output.frameLength)
        guard frames > 0,
              let floatChannel = output.floatChannelData?[0] else { return }

        // Float32 [-1, 1] → Int16 LE.
        var pcm16 = Data(count: frames * MemoryLayout<Int16>.size)
        pcm16.withUnsafeMutableBytes { rawBuffer in
            let intBuffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let clamped = max(-1, min(1, floatChannel[i]))
                // 32767, not 32768, to avoid wrap on +1.0 sample.
                intBuffer[i] = Int16(clamped * 32767.0)
            }
        }

        // Diagnostic: post-conversion RMS, paired with the native RMS
        // logged above. Same chunks only.
        if diagnosticChunkCount < Self.diagnosticChunkLimit {
            let convertedRMS = pcm16RMS(pcm16)
            logger.info("Mic chunk \(self.diagnosticChunkCount, privacy: .public): converted frames=\(frames, privacy: .public) RMS=\(convertedRMS, privacy: .public)")
            diagnosticChunkCount += 1
        }

        // Authoritative accumulator update under lock. AppModel.stop()
        // pulls this atomically — there's no MainActor-dispatch race.
        bufferLock.lock()
        collectedBuffer.append(pcm16)
        bufferLock.unlock()

        onPCMChunk?(pcm16)
    }

    // MARK: - CoreAudio device binding

    /// Bind an input device to the AVAudioEngine inputNode's underlying
    /// AUHAL AudioUnit. If `preferredUID` is non-nil and resolves to a
    /// connected device, that device is bound; otherwise we fall back to
    /// the system default. Without this step, macOS may hand back a
    /// phantom silent stream instead of real hardware audio.
    private static func bindInputDevice(
        to input: AVAudioInputNode,
        preferredUID: String?,
        logger: Logger
    ) throws {
        let resolved: (deviceID: AudioDeviceID, name: String, source: String)
        if let uid = preferredUID, let did = deviceID(forUID: uid) {
            resolved = (did, deviceName(did), "preferred uid=\(uid)")
        } else {
            if let uid = preferredUID {
                logger.warning("Preferred input device uid=\(uid, privacy: .public) not found; falling back to system default")
            }
            guard let did = defaultInputDeviceID() else {
                logger.error("Could not query system default input device")
                throw CaptureError.noInputDevice
            }
            resolved = (did, deviceName(did), "default")
        }
        logger.info("Binding to \(resolved.source, privacy: .public) input device id=\(resolved.deviceID, privacy: .public) name=\(resolved.name, privacy: .public)")

        guard let audioUnit = input.audioUnit else {
            logger.error("AVAudioEngine.inputNode.audioUnit is nil — engine not initialized")
            throw CaptureError.noInputDevice
        }

        var did = resolved.deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &did,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if setStatus != noErr {
            logger.error("AudioUnitSetProperty(CurrentDevice) failed: OSStatus=\(setStatus, privacy: .public)")
            throw CaptureError.noInputDevice
        }
    }

    /// Enumerate every CoreAudio device that has at least one input
    /// stream. Used by the Settings UI to populate a device picker.
    static func availableInputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = deviceIDs.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &size, buf.baseAddress!
            )
        }
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard hasInputChannels(id), let uid = deviceUID(id) else { return nil }
            return InputDevice(uid: uid, name: deviceName(id), deviceID: id)
        }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Look up an AudioDeviceID by UID. The system property
    /// `kAudioHardwarePropertyTranslateUIDToDevice` does this in one
    /// call; we pass the UID via the qualifier pointer and read the
    /// device ID back through the data pointer.
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF = uid as CFString
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uidCF) { qPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, qualifierSize, qPtr, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr else { return false }

        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        for buffer in buffers where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else {
            return "<unknown>"
        }
        return cfName as String
    }

    private func nativeBufferRMS(_ buffer: AVAudioPCMBuffer) -> Double {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channels = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        var sumSquares = 0.0
        for ch in 0..<channelCount {
            let ptr = channels[ch]
            for i in 0..<frameCount {
                let s = Double(ptr[i])
                sumSquares += s * s
            }
        }
        return (sumSquares / Double(frameCount * channelCount)).squareRoot()
    }

    private func pcm16RMS(_ data: Data) -> Double {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return 0 }
        var sumSquares = 0.0
        data.withUnsafeBytes { rawBuffer in
            let intBuffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let s = Double(intBuffer[i]) / 32768.0
                sumSquares += s * s
            }
        }
        return (sumSquares / Double(frameCount)).squareRoot()
    }
}
