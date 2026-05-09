import AppKit
import SwiftUI

/// SwiftUI's `.regularMaterial` blends WITHIN the window, which renders as a
/// flat gray when the window has no other SwiftUI content to blur. To get
/// the macOS frosted-glass effect that shows the desktop through the panel,
/// drop a real `NSVisualEffectView` with `.behindWindow` blending into the
/// background.
private struct VibrancyBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let opacity: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.alphaValue = opacity
    }
}

struct CompactPanelView: View {
    @EnvironmentObject private var model: AppModel

    private var needsModelDownload: ModelVariant? {
        if case .needsDownload(let v) = model.modelStatus { return v }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.streamingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let variant = needsModelDownload {
                modelMissingRow(variant: variant)
            } else if model.isCapturingAudio {
                WaveformView(levels: model.waveformLevels)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                Text(compactText)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 340, height: 110)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.74))
                .background {
                    VibrancyBackground(material: .hudWindow, opacity: 0.10)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.18),
                                    .white.opacity(0.04),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(red: 0.22, green: 0.92, blue: 0.88).opacity(0.34), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
        }
        .foregroundStyle(.white)
        .tint(Color(red: 0.34, green: 0.98, blue: 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func modelMissingRow(variant: ModelVariant) -> some View {
        Button {
            model.requestOpenSettings()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("语音模型未下载")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                    Text("\(variant.displayName) · 点此打开设置下载")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var compactText: String {
        // Use the privacy-cleared compactTranscript, NOT liveTranscript —
        // we don't want the last spoken sentence to sit on screen after
        // it's already been pasted into the focused app.
        if !model.compactTranscript.isEmpty {
            return model.compactTranscript
        }
        if model.connectionState == .subscribed {
            return "Ready"
        }
        return model.connectionState.displayName
    }

    private var statusColor: Color {
        // Mode-agnostic: red whenever a PTT session is live (BLE streaming
        // OR mic capture). Otherwise fall back to BLE-specific signals.
        if model.isCapturingAudio { return .red }
        switch model.streamState.remoteState {
        case .armed:
            return .green
        default:
            return model.connectionState == .subscribed ? .green : .secondary
        }
    }
}

private struct WaveformView: View {
    let levels: [Double]

    var body: some View {
        GeometryReader { geometry in
            let barCount = max(levels.count, 1)
            let spacing: CGFloat = 3
            let barWidth = max(2, (geometry.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: barWidth, height: max(4, geometry.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
