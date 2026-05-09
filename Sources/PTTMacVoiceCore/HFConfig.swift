import Foundation

// Hugging Face endpoint configuration.
//
// The Qwen3-ASR weights are pulled from huggingface.co (or a mirror) on
// first launch via swift-transformers' `HubApi`. The user picks a download
// source in Settings (DownloadSource), persisted in UserDefaults under
// `asrDownloadSource`. We read it here at process start and set
// `HF_ENDPOINT` accordingly BEFORE AppDelegate / AppModel / LocalASRClient
// construct any HubApi instance.
//
// `setenv` is called with overwrite=1 so the picker is authoritative — a
// shell-exported `HF_ENDPOINT` from the user's environment will NOT win
// over the in-app choice. The UI displays the resolved endpoint
// (`getenv("HF_ENDPOINT")`) so any past expectation that env wins is
// transparently surfaced.
//
// HubApi reads `HF_ENDPOINT` once and caches it — switching between
// HF-typed sources mid-process is a no-op. AppModel surfaces a "重启后生效"
// hint when the user picks a different HF endpoint than the launch-time
// value. ModelScope avoids HubApi entirely (see ModelScopeDownloader), so
// switching to/from ModelScope is hot.
public enum HFConfig {
    public static let defaultEndpoint = "https://hf-mirror.com"
    public static let downloadSourceKey = "asrDownloadSource"

    public static func configure(source: DownloadSource = persistedSource()) {
        // ModelScope mode never hits HubApi, but keep a valid host in
        // HF_ENDPOINT as a defensive default in case any code path
        // dereferences it.
        let endpoint = source.hfEndpoint ?? defaultEndpoint
        setenv("HF_ENDPOINT", endpoint, 1)
    }

    public static func persistedSource() -> DownloadSource {
        if let raw = UserDefaults.standard.string(forKey: downloadSourceKey),
           let source = DownloadSource(rawValue: raw) {
            return source
        }
        return .default
    }
}
