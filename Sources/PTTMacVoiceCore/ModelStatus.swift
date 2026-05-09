import Foundation

// The two MLX-quantized variants of Qwen3-ASR that speech-swift's
// ASRModelSize enum maps to. Raw value is the HuggingFace repo id consumed
// by Qwen3ASRModel.fromPretrained — keeping it here as the truth source so
// the rest of the app uses ModelVariant.rawValue instead of magic strings.
enum ModelVariant: String, CaseIterable, Identifiable, Codable {
    case large = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    case small = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .large: return "Qwen3-ASR 1.7B (MLX 8-bit)"
        case .small: return "Qwen3-ASR 0.6B (MLX 4-bit)"
        }
    }

    // Conservative published-size estimate. speech-swift's HuggingFaceDownloader
    // discards the per-file Foundation.Progress and only forwards a fraction,
    // so we can't ask the network for the real total. These numbers come from
    // the actual safetensors+tokenizer payload sizes on HF and are stable
    // across re-downloads.
    var estimatedBytes: Int64 {
        switch self {
        case .large: return 2_500_000_000   // ~2.5 GB
        case .small: return 600_000_000     // ~0.6 GB
        }
    }

    static let `default`: ModelVariant = .large
}

struct DownloadProgress: Equatable {
    var fraction: Double           // 0...1, from speech-swift progressHandler
    var stage: String              // "Downloading model..." / "Loading weights..."
    var bytesDone: Int64           // estimated: fraction × bytesTotal
    var bytesTotal: Int64          // variant.estimatedBytes
    var bytesPerSec: Double        // rolling 5s window; 0 until first sample
    var etaSeconds: Double?        // nil until we have ≥1s of motion
}

enum ModelStatus: Equatable {
    case checkingCache
    case needsDownload(variant: ModelVariant)
    case downloading(variant: ModelVariant, progress: DownloadProgress)
    case loading(variant: ModelVariant)
    case ready(variant: ModelVariant, sizeOnDisk: Int64?)
    case failed(variant: ModelVariant, errorDescription: String)

    var variant: ModelVariant? {
        switch self {
        case .checkingCache: return nil
        case .needsDownload(let v),
             .downloading(let v, _),
             .loading(let v),
             .ready(let v, _),
             .failed(let v, _): return v
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .loading, .checkingCache: return true
        default: return false
        }
    }
}
