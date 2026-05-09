import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                header
                deviceList
                Divider()
                audioInputPanel
                Divider()
                permissionsPanel
                Spacer(minLength: 0)
            }
            .padding()
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelLoadPanel
                    promptPanel
                    pastePanel
                    PerformancePanel(monitor: model.perfMonitor)
                }
                .padding()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PTT BLE Voice")
                .font(.title2.weight(.semibold))
            HStack {
                Button("Scan") { model.startScan() }
                Button("Stop") { model.stopScan() }
                Button("Disconnect") { model.disconnect() }
                Button("Hide") { model.toggleExpanded() }
            }
        }
    }

    private var deviceList: some View {
        List(model.devices) { device in
            DeviceRow(device: device)
        }
    }

    private var modelLoadPanel: some View {
        SpeechModelCard()
    }

    private var promptPanel: some View {
        ASRPromptPanel()
    }

    private var audioInputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Input")
                .font(.headline)
            Picker("Source", selection: Binding(
                get: { model.inputSource },
                set: { model.setInputSource($0) }
            )) {
                ForEach(InputSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.inputSource.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.inputSource == .systemMicrophone {
                microphoneDevicePicker
                inlineMicPermissionAction
            }
        }
        .onAppear {
            if model.inputSource == .systemMicrophone {
                model.refreshAvailableMicrophones()
            }
        }
    }

    private var microphoneDevicePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Microphone Device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshAvailableMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Refresh device list")
            }
            Picker("Microphone Device", selection: Binding(
                get: { model.selectedMicrophoneUID },
                set: { model.setMicrophoneUID($0) }
            )) {
                Text("系统默认").tag(String?.none)
                ForEach(model.availableMicrophones) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
                // If a previously-pinned UID isn't in the current list,
                // surface it explicitly so the user can recognize the
                // unplugged device and pick something else.
                if let uid = model.selectedMicrophoneUID,
                   !model.availableMicrophones.contains(where: { $0.uid == uid }) {
                    Text("\(uid) (unplugged)").tag(String?.some(uid))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isCapturingAudio)
        }
    }

    // Inline action right under the Audio Input picker. AVCaptureDevice's
    // requestAccess only fires the system prompt the first time; once
    // denied, macOS won't ask again, so we deep-link into System Settings
    // for that case. Authorized state collapses to no-op text.
    @ViewBuilder
    private var inlineMicPermissionAction: some View {
        switch model.microphonePermission {
        case .authorized:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("麦克风权限已授予")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notDetermined:
            Button {
                model.requestMicrophonePermission()
            } label: {
                Label("授予麦克风权限", systemImage: "mic.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 4) {
                Text("⚠️ 麦克风权限已拒绝")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("打开系统设置", systemImage: "gear")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        @unknown default:
            EmptyView()
        }
    }

    private var pastePanel: some View {
        let isEmpty = model.liveTranscript.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Text("Text Input")
                .font(.headline)
            ScrollView {
                Text(isEmpty ? "No transcript yet" : model.liveTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
                    .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
            }
            .frame(minHeight: 100, maxHeight: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.headline)
            accessibilityRow
            Divider()
            microphoneRow
        }
    }

    private var accessibilityRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility")
                    .font(.subheadline)
                Text(model.accessibilityTrusted
                     ? "Ready to paste into the focused app"
                     : "Grant Accessibility permission in System Settings")
                    .font(.caption)
                    .foregroundStyle(model.accessibilityTrusted ? Color.secondary : Color.orange)
            }
            Spacer()
            Button(model.accessibilityTrusted ? "Granted" : "Enable") {
                model.requestAccessibilityPermission()
            }
            .disabled(model.accessibilityTrusted)
            Button("Check") {
                model.refreshAccessibilityTrust()
            }
        }
    }

    private var microphoneRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone")
                    .font(.subheadline)
                Text(microphoneStatusCaption)
                    .font(.caption)
                    .foregroundStyle(microphoneStatusColor)
            }
            Spacer()
            switch model.microphonePermission {
            case .authorized:
                Button("Granted") {}
                    .disabled(true)
            case .denied, .restricted:
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .notDetermined:
                Button("Enable") {
                    model.requestMicrophonePermission()
                }
            @unknown default:
                Button("Enable") {
                    model.requestMicrophonePermission()
                }
            }
            Button("Check") {
                model.refreshMicrophonePermission()
            }
        }
    }

    private var microphoneStatusCaption: String {
        switch model.microphonePermission {
        case .authorized:        return "Mic capture allowed"
        case .denied, .restricted: return "Denied — enable in System Settings → Privacy"
        case .notDetermined:     return "Not yet requested"
        @unknown default:        return "Unknown"
        }
    }

    private var microphoneStatusColor: Color {
        switch model.microphonePermission {
        case .authorized: return .secondary
        default:          return .orange
        }
    }

}

private struct ASRPromptPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: UUID?
    @State private var nameDraft: String = ""
    @State private var promptDraft: String = ""
    @State private var cleanupDraft: Bool = true

    private var selectedProfile: ASRPromptProfile? {
        guard let selectedID else { return nil }
        return model.promptProfiles.first(where: { $0.id == selectedID })
    }

    private var isDirty: Bool {
        guard let p = selectedProfile else { return false }
        return p.name != nameDraft
            || p.prompt != promptDraft
            || p.cleanupEnabled != cleanupDraft
    }

    private var selectionIsActive: Bool {
        selectedID != nil && selectedID == model.activePromptID
    }

    private var canResetToTemplate: Bool {
        guard let p = selectedProfile,
              let key = p.builtInKey,
              let tmpl = ASRPromptTemplate.template(forKey: key) else { return false }
        return tmpl.name != nameDraft
            || tmpl.prompt != promptDraft
            || tmpl.cleanupEnabled != cleanupDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASR Prompt")
                .font(.headline)
            HStack(alignment: .top, spacing: 10) {
                profileList
                    .frame(width: 160)
                editor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = model.activePromptID ?? model.promptProfiles.first?.id
                loadDrafts()
            }
        }
        .onChange(of: selectedID) { _, _ in
            loadDrafts()
        }
        .onChange(of: model.promptProfiles) { _, profiles in
            if let sid = selectedID, !profiles.contains(where: { $0.id == sid }) {
                selectedID = model.activePromptID ?? profiles.first?.id
            }
            if !isDirty { loadDrafts() }
        }
    }

    private func loadDrafts() {
        guard let p = selectedProfile else {
            nameDraft = ""
            promptDraft = ""
            cleanupDraft = true
            return
        }
        nameDraft = p.name
        promptDraft = p.prompt
        cleanupDraft = p.cleanupEnabled
    }

    private func save() {
        guard let id = selectedID else { return }
        model.renameProfile(id: id, to: nameDraft)
        model.updateProfilePrompt(id: id, prompt: promptDraft)
        model.setProfileCleanupEnabled(id: id, enabled: cleanupDraft)
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(selection: $selectedID) {
                ForEach(model.promptProfiles) { profile in
                    HStack(spacing: 4) {
                        Image(systemName: profile.id == model.activePromptID
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(profile.id == model.activePromptID
                                             ? Color.green : Color.secondary.opacity(0.4))
                            .imageScale(.small)
                        Text(profile.name)
                            .lineLimit(1)
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 130, maxHeight: 170)

            HStack(spacing: 6) {
                Button {
                    if let id = model.addNewProfile() {
                        selectedID = id
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAddPromptProfile)
                .help(model.canAddPromptProfile
                      ? "Add profile"
                      : "已达上限 (\(AppModel.maxPromptProfiles))")

                Button {
                    if let id = selectedID { model.deleteProfile(id: id) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(model.promptProfiles.count <= 1 || selectedID == nil)
                .help("Delete profile")

                Spacer()

                Text("\(model.promptProfiles.count) / \(AppModel.maxPromptProfiles)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Profile name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                statusBadge
            }

            TextEditor(text: $promptDraft)
                .font(.system(.caption, design: .default))
                .frame(minHeight: 90, maxHeight: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            // The LLM cleanup row only shows when TranscriptCleaner.isEnabled
            // is on (currently false because Apple Intelligence is gated by
            // region in our target markets). When the kill switch flips back
            // to true the toggle reappears with no other changes needed.
            if TranscriptCleaner.isEnabled {
                HStack(spacing: 6) {
                    Toggle(isOn: $cleanupDraft) {
                        Text("LLM cleanup")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Apply Apple Foundation Models polish to remove fillers, fix casing, and merge self-corrections.")
                    if !TranscriptCleaner.isAvailable {
                        Text("(unavailable)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }

            HStack {
                if canResetToTemplate {
                    Button("Reset to template") {
                        guard let id = selectedID else { return }
                        model.resetProfileToTemplate(id: id)
                        loadDrafts()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Spacer()
                Button("Discard") { loadDrafts() }
                    .disabled(!isDirty)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .buttonStyle(.bordered)
                    .disabled(!isDirty)
                Button(selectionIsActive ? "Active" : "Set Active") {
                    guard let id = selectedID else { return }
                    model.setActiveProfile(id: id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedID == nil || selectionIsActive || isDirty)
            }

            Text("Prepended to the decoder prompt as natural-language context. Save edits before activating; the active profile is used on the next transcription.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isDirty {
            badge("Unsaved", fg: .orange, bg: Color.orange.opacity(0.18))
        } else if selectionIsActive {
            badge("Active", fg: .green, bg: Color.green.opacity(0.18))
        } else {
            badge("Saved", fg: .secondary, bg: Color.secondary.opacity(0.15))
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(Capsule())
    }
}

// MARK: - PerformancePanel

private struct PerformancePanel: View {
    @ObservedObject var monitor: PerformanceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Performance")
                    .font(.headline)
                if !monitor.isSampling {
                    Text("paused (app inactive)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    label("Memory")
                    Text(formatBytes(monitor.memoryFootprintBytes))
                        .font(.system(.body, design: .monospaced))
                    captionLabel("Process resident incl. MLX weights (Apple Silicon unified memory)")
                }
                GridRow {
                    label("CPU")
                    Text(formatPercent(monitor.cpuPercent))
                        .font(.system(.body, design: .monospaced))
                    captionLabel("Sum across all cores; up to ~800% on M-series Pro")
                }
                GridRow {
                    label("GPU")
                    Text(formatBytes(monitor.gpuAllocatedBytes))
                        .font(.system(.body, design: .monospaced))
                    captionLabel("Metal device-wide allocation (system, not per-app)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func captionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .memory
        return f.string(fromByteCount: Int64(bytes))
    }

    private func formatPercent(_ percent: Double) -> String {
        if percent < 1 {
            return String(format: "%.1f%%", percent)
        }
        return String(format: "%.0f%%", percent)
    }
}

extension BLEConnectionState {
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .subscribed: "Subscribed"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

// MARK: - DeviceRow

private struct DeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let device: DiscoveredVoiceDevice

    private var isActive: Bool { model.activeDeviceID == device.id }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.headline)
                    if isActive {
                        statusBadge
                    }
                }
                Text("RSSI \(device.rssi) · \(device.discoverySource)")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isActive {
                Button("Disconnect") {
                    model.disconnect()
                }
            } else {
                Button("Connect") {
                    model.connect(device)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.connectionState {
        case .connecting:
            badge("Connecting", fg: .orange, bg: Color.orange.opacity(0.18))
        case .connected:
            badge("Connected", fg: .blue, bg: Color.blue.opacity(0.16))
        case .subscribed:
            badge("Ready", fg: .green, bg: Color.green.opacity(0.18))
        case .failed:
            badge("Failed", fg: .red, bg: Color.red.opacity(0.18))
        case .idle, .scanning:
            // Active device with idle/scanning state — auto-reconnect window.
            badge("Reconnecting", fg: .orange, bg: Color.orange.opacity(0.18))
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(Capsule())
    }
}

// MARK: - SpeechModelCard

private struct SpeechModelCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            variantPicker
            stateBody
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Speech Model")
                .font(.headline)
            statePill
            Spacer()
        }
    }

    @ViewBuilder
    private var statePill: some View {
        switch model.modelStatus {
        case .checkingCache:
            pill("Checking…", fg: .secondary, bg: Color.secondary.opacity(0.15))
        case .needsDownload:
            pill("Not downloaded", fg: .orange, bg: Color.orange.opacity(0.18))
        case .downloading:
            pill("Downloading", fg: .blue, bg: Color.blue.opacity(0.16))
        case .loading:
            pill("Loading", fg: .blue, bg: Color.blue.opacity(0.16))
        case .ready:
            pill("Ready", fg: .green, bg: Color.green.opacity(0.18))
        case .failed:
            pill("Failed", fg: .red, bg: Color.red.opacity(0.18))
        }
    }

    private var variantPicker: some View {
        HStack {
            Text("Variant")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Variant", selection: Binding(
                get: { model.activeModelVariant },
                set: { model.switchModelVariant($0) }
            )) {
                ForEach(ModelVariant.allCases) { variant in
                    Text(variant.displayName).tag(variant)
                }
            }
            .labelsHidden()
            .disabled(model.modelStatus.isBusy)
            Spacer()
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch model.modelStatus {
        case .checkingCache:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking local cache…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .needsDownload(let variant):
            needsDownloadBody(variant: variant)

        case .downloading(_, let progress):
            downloadingBody(progress: progress)

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading weights into memory…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .ready(let variant, let size):
            readyBody(variant: variant, size: size)

        case .failed(_, let errorDescription):
            failedBody(errorDescription: errorDescription)
        }
    }

    private func needsDownloadBody(variant: ModelVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approx. \(SpeechModelCard.bytes(variant.estimatedBytes)) will be downloaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            cacheLocationLine
            endpointLine
            HStack {
                Spacer()
                Button {
                    model.startModelDownload()
                } label: {
                    Label("Download model", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func downloadingBody(progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Cancel", role: .destructive) {
                    model.cancelModelDownload()
                }
                .controlSize(.small)
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
            HStack(spacing: 6) {
                Text("\(SpeechModelCard.bytes(progress.bytesDone)) / \(SpeechModelCard.bytes(progress.bytesTotal))")
                if progress.bytesPerSec > 1024 {
                    Text("·")
                    Text("\(SpeechModelCard.bytes(Int64(progress.bytesPerSec)))/s")
                }
                if let eta = progress.etaSeconds, eta > 1, eta < 24 * 3600 {
                    Text("·")
                    Text("~\(SpeechModelCard.duration(eta)) left")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(progress.stage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func readyBody(variant: ModelVariant, size: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(size.map { "\(SpeechModelCard.bytes($0)) on disk" } ?? "Cached on disk")
                .font(.caption)
                .foregroundStyle(.secondary)
            cacheLocationLine
            endpointLine
            HStack {
                Button {
                    model.revealModelInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button {
                    model.redownloadModel()
                } label: {
                    Label("Re-download", systemImage: "arrow.clockwise")
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func failedBody(errorDescription: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(errorDescription)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            endpointLine
            HStack {
                Button {
                    model.startModelDownload()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    model.revealModelInFinder()
                } label: {
                    Label("Open cache folder", systemImage: "folder")
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var cacheLocationLine: some View {
        let path = (try? LocalASRClient.cacheDirectory(for: model.activeModelVariant.rawValue))?.path
            ?? "(unavailable)"
        return HStack(spacing: 4) {
            Text("Cache:")
                .foregroundStyle(.secondary)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var endpointLine: some View {
        // Source label on its own line so the Picker can take the full
        // card width — the option labels ("HF 镜像 (hf-mirror.com)", etc.)
        // get truncated by NSPopUpButton when sharing an HStack with the
        // label.
        VStack(alignment: .leading, spacing: 4) {
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Source", selection: Binding(
                get: { model.downloadSource },
                set: { model.setDownloadSource($0) }
            )) {
                ForEach(DownloadSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.modelStatus.isBusy)
            // Resolved endpoint — shows the host HubApi will actually hit
            // for HF-typed sources, or modelscope.cn for ModelScope.
            // Truthful even if a shell-exported HF_ENDPOINT tried to
            // override (setenv runs with overwrite=1).
            Text(resolvedSourceCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.requiresRestartHint {
                Text("重启后生效")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var resolvedSourceCaption: String {
        switch model.downloadSource {
        case .modelScope:
            return "Endpoint: modelscope.cn"
        case .hfMirror, .hfOfficial:
            let endpoint = ProcessInfo.processInfo.environment["HF_ENDPOINT"]
                ?? HFConfig.defaultEndpoint
            return "Endpoint: \(endpoint)"
        }
    }

    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(Capsule())
    }

    private static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
