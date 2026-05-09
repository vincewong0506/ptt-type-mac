import Foundation

// Where ASR weights are pulled from on first run. The repo path
// (`aufklarer/Qwen3-ASR-…`) is identical across all three platforms; only
// the host and protocol differ. HF-typed sources go through
// swift-transformers' HubApi via `HF_ENDPOINT`. ModelScope is downloaded
// by `ModelScopeDownloader` directly into the same on-disk cache, so
// `HuggingFaceDownloader.downloadWeights` short-circuits when invoked
// with `offlineMode: true`.
public enum DownloadSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case hfMirror
    case hfOfficial
    case modelScope

    public static let `default`: DownloadSource = .modelScope

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hfMirror:   return "HF 镜像 (hf-mirror.com)"
        case .hfOfficial: return "HuggingFace 官方"
        case .modelScope: return "ModelScope (魔搭)"
        }
    }

    // HF endpoint for HubApi. nil for ModelScope — we never use HubApi in
    // that mode, but `HFConfig.configure` still falls back to hf-mirror so
    // any incidental HubApi reference doesn't end up with an empty host.
    public var hfEndpoint: String? {
        switch self {
        case .hfMirror:   return "https://hf-mirror.com"
        case .hfOfficial: return "https://huggingface.co"
        case .modelScope: return nil
        }
    }
}
