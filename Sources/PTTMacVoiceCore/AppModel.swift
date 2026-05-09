import AppKit
import Foundation
import Combine
import CoreBluetooth
import AVFoundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DiscoveredVoiceDevice] = []
    @Published var streamState = VoiceStreamState()
    @Published var connectionState: BLEConnectionState = .idle
    // The device id BLE client is currently attached to (connecting,
    // connected, or subscribed). Driven by BLEVoiceClient via the
    // onActiveDeviceChanged callback so it stays accurate across
    // user-initiated connects, user disconnects, peripheral-side drops,
    // and silent auto-reconnects to a remembered peripheral.
    @Published var activeDeviceID: UUID?
    @Published var wavFileInfo: WAVFileInfo?
    @Published var isPlayingWAV = false
    @Published var transcript = ""
    @Published var asrStatus = "Idle"
    @Published var isTranscribing = false
    @Published var autoPasteTranscript = true
    @Published var restoreClipboardAfterPaste = true
    @Published var accessibilityTrusted = false
    @Published var isExpanded = false
    @Published var liveTranscript = ""
    // What the floating panel shows. Mirrors `liveTranscript` only briefly:
    // populated when ASR finishes, cleared as soon as the result has been
    // auto-pasted (or paste was attempted), so the user's spoken content
    // doesn't sit on screen above whatever they're working on. The Settings
    // "Text Input" panel keeps using `liveTranscript` so the most recent
    // result stays available for review/copy in a private context.
    @Published var compactTranscript = ""
    @Published var streamingStatus = "Ready"
    @Published var waveformLevels = Array(repeating: 0.08, count: 36)
    // True while a PTT recording session is active, regardless of source.
    // BLE path sets it on streamStart / clears on streamStop. Mic path
    // sets it on .commit (micPromoteToRecording) / clears on
    // .release / .abort. The floating CompactPanelView reads this to
    // decide whether to render the live waveform — using the BLE-only
    // streamState would leave mic-mode sessions showing static text.
    @Published var isCapturingAudio = false
    @Published var modelStatus: ModelStatus = .checkingCache
    @Published var activeModelVariant: ModelVariant = .default
    @Published var downloadSource: DownloadSource = .default
    // True when the picker is on an HF-typed source whose endpoint differs
    // from the launch-time HF_ENDPOINT — HubApi caches the endpoint at
    // first reference, so the change won't take effect until the user
    // restarts. ModelScope is hot, so it never sets this.
    @Published var requiresRestartHint: Bool = false
    @Published var promptProfiles: [ASRPromptProfile] = []
    @Published var activePromptID: UUID?
    // Where ASR audio comes from. `bleDevice` (default) keeps the existing
    // SBC-over-GATT path. `systemMicrophone` switches to Mac-mic capture
    // gated by a global "hold Ctrl" hotkey.
    @Published var inputSource: InputSource = .default
    @Published var microphonePermission: AVAuthorizationStatus = MicrophoneCapture.permissionStatus
    /// User-pinned input device UID. nil means "follow whatever macOS
    /// reports as the system default at every PTT press." Persisted to
    /// UserDefaults under `microphoneUIDKey`.
    @Published var selectedMicrophoneUID: String?
    /// Snapshot of currently-connected input devices. Refreshed on
    /// demand by the Settings UI (`onAppear` + Refresh button).
    @Published var availableMicrophones: [MicrophoneCapture.InputDevice] = []
    var onToggleDebugWindow: (() -> Void)?
    var onRequestOpenSettings: (() -> Void)?

    let bleClient: BLEVoiceClient
    private let sbcDecoder = SBCFrameDecoder()
    private let wavRecorder = WAVFileRecorder()
    private let asrClient = LocalASRClient()
    private let cleaner = TranscriptCleaner()
    private let textInjector = TextInjector()
    private let micCapture = MicrophoneCapture()
    private let hotkeyMonitor = PTTHotkeyMonitor()
    private var wavPlayer: AVAudioPlayer?
    private var sessionPCMBuffer = Data()
    // Cap session capture at the ASR encoder window so a stuck-Ctrl scenario
    // doesn't grow the buffer indefinitely. Slightly under the 120s ceiling
    // so the transcribe call has headroom.
    private var micCaptureCutoffBytes: Int {
        let seconds: Double = LocalASRClient.maxAudioSeconds - 5
        return Int(seconds) * LocalASRClient.sampleRate * MemoryLayout<Int16>.size
    }
    private var cancellables = Set<AnyCancellable>()

    // Model download bookkeeping. The Task ref is held so the user's Cancel
    // button can reach the in-flight HF snapshot. `progressSamples` is a
    // small ring buffer of (timestamp, fraction) pairs used to compute a
    // smoothed bytes/sec speed and an ETA — speech-swift's progressHandler
    // hands us only a fraction, so we sample over time ourselves.
    private var modelLoadTask: Task<Void, Never>?
    private var modelLoadStartedAt: Date?
    private var progressSamples: [(at: Date, fraction: Double)] = []
    private static let progressSampleWindow: TimeInterval = 5.0

    // Avoid auto-popping the Settings window on every PTT press while the
    // user is staring at a "needs download" hint they're choosing to ignore.
    // Reset to false once a model becomes ready, so the next time the user
    // ends up in needs-download we'll surface Settings again.
    private var didAutoOpenSettingsForMissingModel = false

    private static let promptProfilesKey = "asrPromptProfiles"
    private static let activePromptIDKey = "asrPromptActiveID"
    private static let legacyPromptKey = "asrPrompt"
    private static let modelVariantKey = "asrModelVariant"
    private static let inputSourceKey = "asrInputSource"
    private static let microphoneUIDKey = "asrMicrophoneUID"

    // Cap on user-created profiles. Cheap UX guardrail — picker stays
    // navigable, UserDefaults JSON blob stays small. Bump if a user with
    // genuine need shows up.
    static let maxPromptProfiles = 10
    var canAddPromptProfile: Bool {
        promptProfiles.count < Self.maxPromptProfiles
    }

    // Captured at AppModel init from the env var that HFConfig.configure set
    // earlier in process startup. Used to decide when the restart hint must
    // be shown — if the user picks an HF source whose endpoint differs from
    // this value, HubApi has already locked in the old one.
    private let launchTimeHFEndpoint: String?
    private let launchTimeSource: DownloadSource

    var activePromptProfile: ASRPromptProfile? {
        guard let activePromptID else { return nil }
        return promptProfiles.first(where: { $0.id == activePromptID })
    }

    var activePromptText: String {
        activePromptProfile?.prompt ?? LocalASRClient.defaultPrompt
    }

    init() {
        // Capture launch-time HF endpoint BEFORE anything else. HFConfig
        // already ran and set HF_ENDPOINT based on the persisted source.
        self.launchTimeHFEndpoint = ProcessInfo.processInfo.environment["HF_ENDPOINT"]
        self.launchTimeSource = HFConfig.persistedSource()
        self.downloadSource = self.launchTimeSource

        self.bleClient = BLEVoiceClient()

        self.bleClient.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in self?.devices = devices }
        }
        self.bleClient.onStateChanged = { [weak self] state in
            Task { @MainActor in self?.connectionState = state }
        }
        self.bleClient.onActiveDeviceChanged = { [weak self] id in
            Task { @MainActor in self?.activeDeviceID = id }
        }
        self.bleClient.onLog = { [weak self] message in
            Task { @MainActor in self?.appendLog(message) }
        }
        self.bleClient.onPacket = { [weak self] packet in
            Task { @MainActor in self?.handle(packet: packet) }
        }

        wavFileInfo = wavRecorder.currentInfo()
        accessibilityTrusted = textInjector.isTrusted

        loadPromptProfiles()
        let initialPrompt = activePromptText
        Task { [asrClient] in
            await asrClient.setPrompt(initialPrompt)
        }

        // dropFirst skips the initial CombineLatest emission so the load above
        // doesn't trigger a write-back on launch; only user edits propagate.
        Publishers.CombineLatest($promptProfiles, $activePromptID)
            .dropFirst()
            .sink { [weak self] profiles, activeID in
                guard let self else { return }
                self.persistProfiles(profiles, activeID: activeID)
                let active = profiles.first(where: { $0.id == activeID })
                let text = active?.prompt ?? LocalASRClient.defaultPrompt
                Task { [asrClient = self.asrClient] in
                    await asrClient.setPrompt(text)
                }
            }
            .store(in: &cancellables)

        if TranscriptCleaner.isEnabled {
            appendLog("Cleanup LLM: \(TranscriptCleaner.availabilityDescription)")
        } else {
            appendLog("Cleanup LLM: disabled at source (TranscriptCleaner.isEnabled = false)")
        }

        // Hydrate the active variant from UserDefaults BEFORE pushing it to
        // asrClient or probing cache state.
        if let stored = UserDefaults.standard.string(forKey: Self.modelVariantKey),
           let variant = ModelVariant(rawValue: stored) {
            activeModelVariant = variant
        }
        let variant = activeModelVariant
        let source = downloadSource
        Task { [asrClient] in
            await asrClient.setModelId(variant.rawValue)
            await asrClient.setDownloadSource(source)
        }

        // Hydrate input source from UserDefaults; default to BLE.
        if let storedSource = UserDefaults.standard.string(forKey: Self.inputSourceKey),
           let parsed = InputSource(rawValue: storedSource) {
            inputSource = parsed
        }

        // Hydrate microphone UID. Empty string sentinel = system default
        // (UserDefaults can't store nil under a String getter cleanly).
        if let raw = UserDefaults.standard.string(forKey: Self.microphoneUIDKey),
           !raw.isEmpty {
            selectedMicrophoneUID = raw
        }
        micCapture.preferredDeviceUID = selectedMicrophoneUID

        // Mic capture chunks fire off the audio render thread — hop to main.
        micCapture.onPCMChunk = { [weak self] pcm in
            Task { @MainActor in self?.handleMicPCMChunk(pcm) }
        }
        // Hotkey events come in already on @MainActor via PTTHotkeyMonitor.
        hotkeyMonitor.onEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        // Only listen to Ctrl when mic mode is active. Toggling here covers
        // both the launch-time hydrated value and any later picker change.
        hotkeyMonitor.isEnabled = (inputSource == .systemMicrophone)

        Task { [weak self] in
            await self?.checkLocalModelStatus()
        }
    }

    // Runs the active profile's optional FoundationModels cleanup pass. Falls
    // back to the raw transcript on any failure so a flaky cleanup never
    // costs the user the recognized text.
    private func applyCleanupIfEnabled(rawText: String) async -> String {
        guard TranscriptCleaner.isEnabled else { return rawText }
        guard let active = activePromptProfile, active.cleanupEnabled else { return rawText }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }
        asrStatus = "Cleaning up..."
        let context = activePromptText
        let started = Date()
        do {
            let cleaned = try await cleaner.clean(rawText: rawText, contextPrompt: context)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            // Surface the actual delta so we can see what FM is (or isn't) doing.
            // Identical strings get a "no-op" tag — that's the case where FM
            // ran but didn't change anything, which is signal in itself.
            appendLog("Cleanup raw    (\(rawText.count) ch): \(rawText)")
            appendLog("Cleanup output (\(cleaned.count) ch, \(ms) ms)\(cleaned == rawText ? " [no-op]" : ""): \(cleaned)")
            return cleaned
        } catch {
            appendLog("Cleanup failed: \(error.localizedDescription); using raw transcript")
            return rawText
        }
    }

    @discardableResult
    func addNewProfile() -> UUID? {
        guard canAddPromptProfile else { return nil }
        var name = "新场景"
        var counter = 2
        while promptProfiles.contains(where: { $0.name == name }) {
            name = "新场景 \(counter)"
            counter += 1
        }
        let profile = ASRPromptProfile(name: name, prompt: "")
        promptProfiles.append(profile)
        return profile.id
    }

    // Refuses to delete the last remaining profile so the active prompt always
    // resolves to something. UI should keep [–] disabled when count == 1.
    func deleteProfile(id: UUID) {
        guard promptProfiles.count > 1 else { return }
        promptProfiles.removeAll { $0.id == id }
        if activePromptID == id {
            activePromptID = promptProfiles.first?.id
        }
    }

    func renameProfile(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = promptProfiles.firstIndex(where: { $0.id == id }) else { return }
        promptProfiles[idx].name = trimmed
    }

    func updateProfilePrompt(id: UUID, prompt: String) {
        guard let idx = promptProfiles.firstIndex(where: { $0.id == id }) else { return }
        promptProfiles[idx].prompt = prompt
    }

    func setProfileCleanupEnabled(id: UUID, enabled: Bool) {
        guard let idx = promptProfiles.firstIndex(where: { $0.id == id }) else { return }
        promptProfiles[idx].cleanupEnabled = enabled
    }

    func setActiveProfile(id: UUID) {
        guard promptProfiles.contains(where: { $0.id == id }) else { return }
        activePromptID = id
    }

    func resetProfileToTemplate(id: UUID) {
        guard let idx = promptProfiles.firstIndex(where: { $0.id == id }),
              let key = promptProfiles[idx].builtInKey,
              let tmpl = ASRPromptTemplate.template(forKey: key) else { return }
        promptProfiles[idx].name = tmpl.name
        promptProfiles[idx].prompt = tmpl.prompt
        promptProfiles[idx].cleanupEnabled = tmpl.cleanupEnabled
    }

    private func loadPromptProfiles() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.promptProfilesKey),
           let decoded = try? JSONDecoder().decode([ASRPromptProfile].self, from: data),
           !decoded.isEmpty {
            // One-off purge: prior versions seeded family + outdoor templates
            // and minted a "已迁移" profile from the pre-profile single-string
            // prompt. We've trimmed the seed list to the engineer template
            // only; residual instances get pruned here so they stop showing
            // up in the picker. User-created profiles are untouched.
            let purged = decoded.filter { profile in
                if let key = profile.builtInKey,
                   ASRPromptTemplate.deprecatedBuiltinKeys.contains(key) {
                    return false
                }
                if profile.builtInKey == nil && profile.name == "已迁移" {
                    return false
                }
                return true
            }
            if !purged.isEmpty {
                promptProfiles = purged
                if let idStr = defaults.string(forKey: Self.activePromptIDKey),
                   let uuid = UUID(uuidString: idStr),
                   purged.contains(where: { $0.id == uuid }) {
                    activePromptID = uuid
                } else {
                    activePromptID = purged.first?.id
                }
                if purged.count != decoded.count {
                    persistProfiles(promptProfiles, activeID: activePromptID)
                }
                return
            }
            // Purged everything (the user only had deprecated/migrated
            // profiles) — fall through to the seed path below.
        }

        // Fresh install or post-purge: seed the built-in template(s).
        let seeded = ASRPromptTemplate.seedProfiles()
        promptProfiles = seeded
        activePromptID = seeded.first?.id
        persistProfiles(promptProfiles, activeID: activePromptID)
        defaults.removeObject(forKey: Self.legacyPromptKey)
    }

    private func persistProfiles(_ profiles: [ASRPromptProfile], activeID: UUID?) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.promptProfilesKey)
        }
        if let activeID {
            defaults.set(activeID.uuidString, forKey: Self.activePromptIDKey)
        } else {
            defaults.removeObject(forKey: Self.activePromptIDKey)
        }
    }

    // MARK: - Model lifecycle

    func requestOpenSettings() {
        onRequestOpenSettings?()
    }

    func checkLocalModelStatus() async {
        let variant = activeModelVariant
        let cached = LocalASRClient.cachedFilesComplete(for: variant.rawValue)
        if cached {
            appendLog("Model cache present for \(variant.displayName) — loading")
            await runModelLoad(variant: variant)
        } else {
            modelStatus = .needsDownload(variant: variant)
            asrStatus = "Model not downloaded"
            appendLog("Model cache missing for \(variant.displayName) — awaiting user")
        }
    }

    func startModelDownload() {
        guard modelLoadTask == nil else { return }
        let variant = activeModelVariant
        appendLog("Starting download for \(variant.displayName) (~\(Self.formatBytes(variant.estimatedBytes)))")
        modelLoadTask = Task { [weak self] in
            await self?.runModelLoad(variant: variant)
        }
    }

    func cancelModelDownload() {
        guard let task = modelLoadTask else { return }
        appendLog("Cancelling model download")
        task.cancel()
        // The Task's catch path puts us back into needsDownload; clear the
        // ref here so a subsequent click re-enters startModelDownload.
        modelLoadTask = nil
    }

    func setDownloadSource(_ value: DownloadSource) {
        guard value != downloadSource else { return }
        // Symmetric with switchModelVariant: don't flip mid-download. The
        // picker is also disabled in the UI during busy states, this is
        // belt-and-suspenders.
        if case .downloading = modelStatus { return }
        if case .loading = modelStatus { return }

        downloadSource = value
        UserDefaults.standard.set(value.rawValue, forKey: HFConfig.downloadSourceKey)

        // Restart hint: only relevant when the new pick is HF-typed AND
        // its endpoint differs from whatever HubApi locked in at launch.
        // ModelScope is hot, so it always clears the hint.
        if let endpoint = value.hfEndpoint, endpoint != launchTimeHFEndpoint {
            requiresRestartHint = true
        } else {
            requiresRestartHint = false
        }

        appendLog("Download source set to \(value.displayName)" + (requiresRestartHint ? " (重启后生效)" : ""))

        Task { [asrClient] in
            await asrClient.setDownloadSource(value)
        }
    }

    func switchModelVariant(_ variant: ModelVariant) {
        guard variant != activeModelVariant else { return }
        // Don't switch mid-download — UI keeps the picker disabled, but
        // belt-and-suspenders.
        if case .downloading = modelStatus { return }
        if case .loading = modelStatus { return }

        activeModelVariant = variant
        UserDefaults.standard.set(variant.rawValue, forKey: Self.modelVariantKey)
        appendLog("Switched active variant to \(variant.displayName)")

        // Push the new id to the asrClient (drops cached model + any
        // in-flight load). Then re-probe cache so the UI updates.
        Task { [asrClient, weak self] in
            await asrClient.setModelId(variant.rawValue)
            await self?.checkLocalModelStatus()
        }
    }

    func redownloadModel() {
        let variant = activeModelVariant
        guard let dir = try? LocalASRClient.cacheDirectory(for: variant.rawValue) else {
            appendLog("Re-download failed: cache directory unavailable")
            return
        }
        do {
            try FileManager.default.removeItem(at: dir)
            appendLog("Cleared cache at \(dir.path)")
        } catch {
            appendLog("Cache wipe failed: \(error.localizedDescription)")
            // fall through and try the download anyway — incomplete cleanup
            // is better than silent inaction.
        }
        // Force the asrClient to drop any cached weights it had open. We
        // bounce the modelId through itself to trigger the reset path.
        Task { [asrClient] in
            await asrClient.setModelId("")
            await asrClient.setModelId(variant.rawValue)
        }
        modelStatus = .needsDownload(variant: variant)
        startModelDownload()
    }

    func revealModelInFinder() {
        let variant = activeModelVariant
        guard let dir = try? LocalASRClient.cacheDirectory(for: variant.rawValue) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // Drives the actual load. Used by checkLocalModelStatus (already cached
    // path), startModelDownload, and redownloadModel.
    private func runModelLoad(variant: ModelVariant) async {
        modelLoadStartedAt = Date()
        progressSamples.removeAll(keepingCapacity: true)
        let initialProgress = DownloadProgress(
            fraction: 0,
            stage: "Preparing",
            bytesDone: 0,
            bytesTotal: variant.estimatedBytes,
            bytesPerSec: 0,
            etaSeconds: nil
        )
        modelStatus = .downloading(variant: variant, progress: initialProgress)
        asrStatus = "Loading 0%"

        do {
            try await asrClient.loadModel { fraction, stage in
                Task { @MainActor [weak self] in
                    self?.handleLoadProgress(fraction: fraction, stage: stage)
                }
            }
            try Task.checkCancellation()
            // Compute size on disk now that we know the cache is whole.
            let size = LocalASRClient.cacheSizeOnDisk(for: variant.rawValue)
            modelStatus = .ready(variant: variant, sizeOnDisk: size > 0 ? size : nil)
            asrStatus = "Idle"
            didAutoOpenSettingsForMissingModel = false
            appendLog("\(variant.displayName) ready (\(Self.formatBytes(size)) on disk)")
        } catch is CancellationError {
            modelStatus = .needsDownload(variant: variant)
            asrStatus = "Cancelled"
            appendLog("Model load cancelled by user")
        } catch {
            let nsErr = error as NSError
            // Foundation surfaces task cancellation as URLError(-999) too.
            if nsErr.code == NSURLErrorCancelled {
                modelStatus = .needsDownload(variant: variant)
                asrStatus = "Cancelled"
                appendLog("Model load cancelled by user")
            } else {
                modelStatus = .failed(variant: variant, errorDescription: error.localizedDescription)
                asrStatus = "Model load failed"
                appendLog("Model load failed: \(error.localizedDescription)")
            }
        }

        modelLoadTask = nil
        modelLoadStartedAt = nil
        progressSamples.removeAll(keepingCapacity: true)
    }

    private func handleLoadProgress(fraction: Double, stage: String) {
        let clamped = max(0, min(1, fraction))
        let variant = activeModelVariant
        let now = Date()

        // Trim ring buffer to window, then append the new sample.
        let cutoff = now.addingTimeInterval(-Self.progressSampleWindow)
        progressSamples.removeAll(where: { $0.at < cutoff })
        progressSamples.append((at: now, fraction: clamped))

        // Speed: bytes/sec across the rolling window.
        var bytesPerSec: Double = 0
        if let first = progressSamples.first, first.at != now {
            let dt = now.timeIntervalSince(first.at)
            let df = clamped - first.fraction
            if dt > 0 {
                bytesPerSec = max(0, df * Double(variant.estimatedBytes) / dt)
            }
        }

        // ETA: extrapolate from total elapsed if we have meaningful motion.
        var eta: Double?
        if clamped > 0.01,
           let started = modelLoadStartedAt,
           now.timeIntervalSince(started) > 1.0 {
            let elapsed = now.timeIntervalSince(started)
            eta = (1 - clamped) * elapsed / clamped
        }

        let progress = DownloadProgress(
            fraction: clamped,
            stage: stage,
            bytesDone: Int64(clamped * Double(variant.estimatedBytes)),
            bytesTotal: variant.estimatedBytes,
            bytesPerSec: bytesPerSec,
            etaSeconds: eta
        )
        modelStatus = .downloading(variant: variant, progress: progress)
        let pct = Int((clamped * 100).rounded())
        asrStatus = "Loading \(pct)% — \(stage)"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // Gates a transcribe call. Returns true only if the model is fully
    // ready. Otherwise updates user-facing state (asrStatus message, log
    // line, optional Settings auto-open) and returns false so the caller
    // can skip the transcribe Task entirely. The captured WAV is preserved
    // either way — no audio is lost, just not transcribed.
    private func ensureModelReadyForTranscribe() -> Bool {
        switch modelStatus {
        case .ready:
            return true
        case .needsDownload(let variant):
            asrStatus = "Skipped — model not downloaded"
            appendLog("Transcribe skipped: \(variant.displayName) not downloaded; open Settings to download")
            if !didAutoOpenSettingsForMissingModel {
                didAutoOpenSettingsForMissingModel = true
                requestOpenSettings()
            }
            return false
        case .downloading(_, let progress):
            let pct = Int((progress.fraction * 100).rounded())
            asrStatus = "Skipped — model downloading (\(pct)%)"
            appendLog("Transcribe skipped: model still downloading at \(pct)%")
            return false
        case .loading:
            asrStatus = "Skipped — model still loading"
            appendLog("Transcribe skipped: model still loading into memory")
            return false
        case .checkingCache:
            asrStatus = "Skipped — checking cache"
            appendLog("Transcribe skipped: cache probe still in flight")
            return false
        case .failed(_, let errorDescription):
            asrStatus = "Skipped — model load failed"
            appendLog("Transcribe skipped: model failed (\(errorDescription)); open Settings to retry")
            if !didAutoOpenSettingsForMissingModel {
                didAutoOpenSettingsForMissingModel = true
                requestOpenSettings()
            }
            return false
        }
    }

    // MARK: - Input source / microphone

    func setInputSource(_ value: InputSource) {
        guard value != inputSource else { return }
        // Don't flip mid-session — mic engine or BLE stream may be live.
        if streamState.remoteState == .streaming { return }
        if hotkeyMonitor.isEnabled, case .recording = micRecordingState { return }

        inputSource = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.inputSourceKey)
        appendLog("Input source switched to \(value.displayName)")

        hotkeyMonitor.isEnabled = (value == .systemMicrophone)

        if value == .systemMicrophone {
            // Lazy permission probe — kicks the system prompt the first
            // time the user opts in. UI also exposes a manual button via
            // requestMicrophonePermission().
            switch MicrophoneCapture.permissionStatus {
            case .notDetermined:
                Task { [weak self] in
                    let granted = await MicrophoneCapture.requestPermission()
                    await MainActor.run {
                        self?.microphonePermission = MicrophoneCapture.permissionStatus
                        self?.appendLog("Microphone permission \(granted ? "granted" : "denied")")
                    }
                }
            default:
                microphonePermission = MicrophoneCapture.permissionStatus
            }
        }
    }

    func requestMicrophonePermission() {
        Task { [weak self] in
            let granted = await MicrophoneCapture.requestPermission()
            await MainActor.run {
                self?.microphonePermission = MicrophoneCapture.permissionStatus
                self?.appendLog("Microphone permission \(granted ? "granted" : "denied")")
            }
        }
    }

    func refreshMicrophonePermission() {
        microphonePermission = MicrophoneCapture.permissionStatus
    }

    /// Switch the pinned input device. nil = follow system default.
    /// Refused mid-PTT to avoid yanking the audio source out from
    /// under an in-flight session.
    func setMicrophoneUID(_ uid: String?) {
        guard uid != selectedMicrophoneUID else { return }
        if isCapturingAudio { return }

        selectedMicrophoneUID = uid
        micCapture.preferredDeviceUID = uid
        // Persist as empty-string sentinel for nil so a later launch's
        // hydration check (`!raw.isEmpty`) routes back to default.
        UserDefaults.standard.set(uid ?? "", forKey: Self.microphoneUIDKey)

        if let uid {
            let label = availableMicrophones.first { $0.uid == uid }?.name ?? uid
            appendLog("Microphone device pinned to \(label) (uid=\(uid))")
        } else {
            appendLog("Microphone device set to system default")
        }
    }

    /// Re-enumerate connected input devices for the Settings picker.
    /// Cheap (a few CoreAudio property reads); call from the panel's
    /// `onAppear` and from a manual Refresh button.
    func refreshAvailableMicrophones() {
        availableMicrophones = MicrophoneCapture.availableInputDevices()
    }

    // Tracks the mic-mode session lifecycle. .tentative captures audio into
    // sessionPCMBuffer silently; only .recording promotes UI to "Listening".
    // This avoids a flicker when Ctrl was actually a shortcut prefix.
    private enum MicRecordingState { case idle, tentative, recording }
    private var micRecordingState: MicRecordingState = .idle

    private func handleHotkeyEvent(_ event: PTTHotkeyMonitor.Event) {
        switch event {
        case .tentative:
            micBeginTentative()
        case .commit:
            micPromoteToRecording()
        case .release:
            micFinishAndTranscribe()
        case .abort:
            micAbort()
        }
    }

    // Bytes captured since current PTT session started, used only for the
    // 120s safety cutoff. Authoritative PCM lives in MicrophoneCapture's
    // internal accumulator; this is just a counter.
    private var micCapturedBytes: Int = 0

    private func micBeginTentative() {
        guard micRecordingState == .idle else { return }
        // Pre-warm: start mic. UI doesn't change so a false-positive
        // Ctrl shortcut produces no visible flicker.
        micCapturedBytes = 0
        sessionPCMBuffer.removeAll(keepingCapacity: true)
        do {
            try micCapture.start()
            micRecordingState = .tentative
        } catch let error as MicrophoneCapture.CaptureError {
            appendLog("Mic capture failed: \(error.localizedDescription)")
            microphonePermission = MicrophoneCapture.permissionStatus
            micRecordingState = .idle
        } catch {
            appendLog("Mic capture failed: \(error.localizedDescription)")
            micRecordingState = .idle
        }
    }

    private func micPromoteToRecording() {
        guard micRecordingState == .tentative else { return }
        micRecordingState = .recording
        waveformLevels = Array(repeating: 0.08, count: 36)
        startWAVRecording()
        transcript = ""
        liveTranscript = ""
        compactTranscript = ""
        asrStatus = "Recording"
        streamingStatus = "Listening"
        isCapturingAudio = true
        // Backfill the WAV file with audio captured during .tentative —
        // pulled from the mic's authoritative accumulator (snapshot, not
        // drain) so the same bytes still feed ASR at finish time.
        let preGrace = micCapture.snapshot()
        if !preGrace.isEmpty {
            try? wavRecorder.appendPCM16(preGrace)
            wavFileInfo = wavRecorder.currentInfo()
        }
        appendLog("Mic PTT committed")
    }

    private func micAbort() {
        switch micRecordingState {
        case .idle:
            return
        case .tentative:
            // Discard return value: nothing should be transcribed.
            _ = micCapture.stop()
            sessionPCMBuffer.removeAll(keepingCapacity: true)
            micCapturedBytes = 0
            micRecordingState = .idle
        case .recording:
            // Stop and discard rather than transcribe a fragment.
            _ = micCapture.stop()
            wavRecorder.finish()
            wavFileInfo = wavRecorder.currentInfo()
            sessionPCMBuffer.removeAll(keepingCapacity: true)
            micCapturedBytes = 0
            isCapturingAudio = false
            streamingStatus = "Ready"
            asrStatus = "Idle"
            micRecordingState = .idle
            appendLog("Mic PTT aborted")
        }
    }

    private func micFinishAndTranscribe() {
        guard micRecordingState == .recording else {
            micAbort()
            return
        }
        micRecordingState = .idle
        isCapturingAudio = false
        // Atomically retrieve every byte captured since start — including
        // any tap callbacks that fired between the user's Ctrl-up event
        // and our `stop()` call. removeTap() blocks until in-flight
        // callbacks finish, so this is race-free.
        let captured = micCapture.stop()
        sessionPCMBuffer = captured
        micCapturedBytes = 0
        wavRecorder.finish()
        wavFileInfo = wavRecorder.currentInfo()
        transcribeSessionPCM()
    }

    private func handleMicPCMChunk(_ pcm: Data) {
        guard inputSource == .systemMicrophone else { return }
        switch micRecordingState {
        case .idle:
            // Late chunk arriving after stop — drop. Authoritative buffer
            // already harvested via `micCapture.stop()`.
            return
        case .tentative:
            // Pre-grace audio is being held inside MicrophoneCapture's
            // accumulator. Don't update UI / WAV here; just track size
            // for the cutoff check.
            micCapturedBytes += pcm.count
            if micCapturedBytes >= micCaptureCutoffBytes {
                appendLog("Mic capture hit ~\(Int(LocalASRClient.maxAudioSeconds) - 5)s cap during grace; aborting")
                micAbort()
            }
        case .recording:
            try? wavRecorder.appendPCM16(pcm)
            appendWaveformLevel(from: pcm)
            wavFileInfo = wavRecorder.currentInfo()
            micCapturedBytes += pcm.count
            if micCapturedBytes >= micCaptureCutoffBytes {
                appendLog("Mic capture hit ~\(Int(LocalASRClient.maxAudioSeconds) - 5)s safety cap; finishing")
                micFinishAndTranscribe()
            }
        }
    }

    func startScan() {
        appendLog("Starting BLE scan")
        bleClient.startScan()
    }

    func stopScan() {
        appendLog("Stopping BLE scan")
        bleClient.stopScan()
    }

    func connect(_ device: DiscoveredVoiceDevice) {
        appendLog("Connecting to \(device.displayName)")
        bleClient.connect(device.id)
    }

    func disconnect() {
        appendLog("Disconnecting")
        bleClient.disconnect()
        finishWAVRecording(runASR: false)
    }

    func queryState() {
        bleClient.sendCommand(.queryState)
    }

    func disarm() {
        bleClient.sendCommand(.disarm)
    }

    func rearm() {
        bleClient.sendCommand(.rearm)
    }

    func ping() {
        bleClient.sendCommand(.ping(UInt32.random(in: 1...UInt32.max)))
    }

    func playWAV() {
        guard let wavFileInfo else { return }
        do {
            wavPlayer?.stop()
            let player = try AVAudioPlayer(contentsOf: wavFileInfo.url)
            wavPlayer = player
            player.prepareToPlay()
            player.play()
            isPlayingWAV = true
            appendLog("Playing \(wavFileInfo.url.path)")
        } catch {
            appendLog("WAV playback failed: \(error.localizedDescription)")
        }
    }

    func stopWAVPlayback() {
        wavPlayer?.stop()
        isPlayingWAV = false
    }

    func transcribeLatestWAV() {
        guard let wavFileInfo else {
            appendLog("No WAV file to transcribe")
            return
        }
        guard wavFileInfo.pcmByteCount > 0 else {
            appendLog("Skipping ASR for empty WAV")
            return
        }
        guard ensureModelReadyForTranscribe() else { return }

        isTranscribing = true
        asrStatus = "Transcribing..."
        appendLog("ASR request: \(wavFileInfo.url.path)")

        Task {
            do {
                let result = try await asrClient.transcribe(wavURL: wavFileInfo.url)
                let finalText = await self.applyCleanupIfEnabled(rawText: result.text)
                await MainActor.run {
                    self.transcript = finalText
                    self.liveTranscript = finalText
                    self.compactTranscript = finalText
                    self.asrStatus = result.language.map { "Done (\($0))" } ?? "Done"
                    self.isTranscribing = false
                    self.appendLog("ASR done: \(finalText)")
                    if self.autoPasteTranscript {
                        self.pasteTranscript()
                    }
                }
            } catch {
                await MainActor.run {
                    self.asrStatus = "Failed"
                    self.isTranscribing = false
                    self.appendLog("ASR failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func requestAccessibilityPermission() {
        textInjector.requestAccessibilityPermission()
        accessibilityTrusted = textInjector.isTrusted
    }

    func refreshAccessibilityTrust() {
        accessibilityTrusted = textInjector.isTrusted
    }

    func pasteTranscript() {
        textInjector.restoreClipboard = restoreClipboardAfterPaste
        do {
            try textInjector.pasteIntoCurrentFocus(transcript)
            accessibilityTrusted = textInjector.isTrusted
            appendLog("Pasted transcript to focused app")
        } catch {
            accessibilityTrusted = textInjector.isTrusted
            appendLog("Paste failed: \(error.localizedDescription)")
        }
        // Privacy: drop the floating-panel mirror regardless of paste
        // outcome — the spoken content shouldn't sit on top of whatever
        // the user is doing. Settings "Text Input" still has liveTranscript
        // for review.
        compactTranscript = ""
    }

    func toggleExpanded() {
        onToggleDebugWindow?()
    }

    func setDebugWindowVisible(_ visible: Bool) {
        isExpanded = visible
    }

    private func handle(packet: VoicePacket) {
        streamState.apply(packet)

        // In mic mode the BLE audio path is muted — we listen for Ctrl HID
        // (which the puck firmware also emits on its physical button) via
        // PTTHotkeyMonitor. The protocol stream packets are kept flowing
        // for telemetry / streamState only; audio side is no-op'd.
        let micMode = inputSource == .systemMicrophone

        switch packet.payload {
        case .streamStart(let info):
            if micMode {
                appendLog("Stream start (BLE audio ignored — mic mode): \(info.sampleRateKHz) kHz")
                break
            }
            sbcDecoder.reset()
            sessionPCMBuffer.removeAll(keepingCapacity: true)
            waveformLevels = Array(repeating: 0.08, count: 36)
            startWAVRecording()
            transcript = ""
            liveTranscript = ""
            compactTranscript = ""
            asrStatus = "Recording"
            streamingStatus = "Listening"
            isCapturingAudio = true
            appendLog("Stream start: \(info.sampleRateKHz) kHz, \(info.channels) ch, frame \(info.frameBytes) bytes")
        case .streamStop(let reason):
            if micMode {
                appendLog("Stream stop ignored — mic mode: \(reason)")
                break
            }
            isCapturingAudio = false
            finishWAVRecording(runASR: false)
            transcribeSessionPCM()
            appendLog("Stream stop: \(reason)")
        case .audioSBC(let info):
            if micMode { break }
            guard !info.frames.isEmpty else {
                appendLog(
                    "AUDIO_SBC malformed: payload=\(info.rawPayloadLength)B, "
                    + "declared n_frames=\(info.declaredFrameCount), "
                    + "expected payload=\(2 + info.declaredFrameCount * 32)B"
                )
                return
            }
            // Protocol §2.0x10 reserves payload[1] as 0. Surface non-zero
            // values so future protocol revisions that overload this byte
            // are not silently ignored.
            if info.reservedByte != 0 {
                appendLog(String(
                    format: "AUDIO_SBC reserved byte != 0 (got 0x%02X)",
                    info.reservedByte
                ))
            }
            do {
                let pcm = try sbcDecoder.decode(frames: info.frames)
                sessionPCMBuffer.append(pcm)
                try wavRecorder.appendPCM16(pcm)
                appendWaveformLevel(from: pcm)
                wavFileInfo = wavRecorder.currentInfo()
            } catch {
                appendLog("SBC decode failed: \(error.localizedDescription)")
            }
        case .heartbeat(let heartbeat):
            // Protocol §3 PING response is a HEARTBEAT with flags.bit1=1 and
            // the nonce echoed in `fedFramesOrNonce`. Distinguish it so we
            // can tell "device replied to my ping" from regular keepalive.
            if heartbeat.isPongResponse {
                appendLog(String(
                    format: "Pong nonce=0x%08X frames=%u overflow=%u",
                    heartbeat.fedFramesOrNonce,
                    heartbeat.sentFrames,
                    heartbeat.overflowFrames
                ))
            } else {
                appendLog(
                    "Heartbeat fed=\(heartbeat.fedFramesOrNonce) "
                    + "sent=\(heartbeat.sentFrames) "
                    + "overflow=\(heartbeat.overflowFrames)"
                )
            }
        case .overflow(let overflow):
            appendLog("Overflow dropped=\(overflow.droppedSinceLast) total=\(overflow.totalDropped)")
        case .status(let status):
            appendLog("Status \(status.state.rawValue), ptt=\(status.pttRecording), mtu=\(status.negotiatedMTU), frames=\(status.mtuFrames)")
        case .unknown(let opcode, let bytes):
            appendLog("Unknown opcode 0x\(String(opcode, radix: 16)) payload=\(bytes.count) bytes")
        }
    }

    private func startWAVRecording() {
        do {
            try wavRecorder.start()
            wavFileInfo = wavRecorder.currentInfo()
            appendLog("Recording WAV to \(wavRecorder.url.path)")
        } catch {
            appendLog("WAV recording failed: \(error.localizedDescription)")
        }
    }

    private func transcribeSessionPCM() {
        guard !sessionPCMBuffer.isEmpty else {
            appendLog("Skipping final ASR for empty PCM buffer")
            return
        }
        guard ensureModelReadyForTranscribe() else {
            // Wipe the captured buffer — without a transcribe pass it
            // would otherwise sit around and leak into the next session.
            sessionPCMBuffer.removeAll(keepingCapacity: true)
            streamingStatus = "Ready"
            return
        }

        let pcm = sessionPCMBuffer
        isTranscribing = true
        asrStatus = "Finalizing..."
        streamingStatus = "Finalizing..."
        appendLog("Final ASR request: \(pcm.count) PCM bytes")

        Task {
            do {
                let result = try await asrClient.transcribePCM16(pcm)
                let finalText = await self.applyCleanupIfEnabled(rawText: result.text)
                await MainActor.run {
                    self.transcript = finalText
                    self.liveTranscript = finalText
                    self.compactTranscript = finalText
                    self.asrStatus = result.language.map { "Done (\($0))" } ?? "Done"
                    self.isTranscribing = false
                    self.appendLog("Final ASR done: \(finalText)")
                    if self.autoPasteTranscript {
                        self.pasteTranscript()
                    }
                }
            } catch {
                await MainActor.run {
                    self.asrStatus = "Failed"
                    self.isTranscribing = false
                    self.appendLog("Final ASR failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func appendWaveformLevel(from pcm: Data) {
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return }

        var sumSquares = 0.0
        pcm.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for sample in samples {
                let normalized = Double(Int16(littleEndian: sample)) / 32768.0
                sumSquares += normalized * normalized
            }
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        let level = min(1.0, max(0.04, rms * 8.0))
        waveformLevels.append(level)
        if waveformLevels.count > 36 {
            waveformLevels.removeFirst(waveformLevels.count - 36)
        }
    }

    private func finishWAVRecording(runASR: Bool) {
        wavRecorder.finish()
        wavFileInfo = wavRecorder.currentInfo()
        if runASR {
            transcribeLatestWAV()
        }
    }

    private static let logger = Logger(
        subsystem: "com.pttcoding.PTTVoice",
        category: "app"
    )

    private func appendLog(_ message: String) {
        // Logger handles its own timestamping; .public is required so the
        // message text shows up in Console.app / `log show` instead of being
        // redacted as private data.
        Self.logger.info("\(message, privacy: .public)")
        // Also mirror to stdout so Xcode's debug console (and `swift run`)
        // surfaces the message immediately without needing Console.app filters.
        print("[PTTVoice] \(message)")
    }
}
