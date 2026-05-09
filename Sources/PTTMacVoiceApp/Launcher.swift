import AppKit
import PTTMacVoiceCore

// Standalone entry for `swift run` and the legacy build-ptt-voice-app.sh
// pipeline. The Xcode App target has its own SwiftUI `@main`; both paths
// reuse the same AppDelegate from PTTMacVoiceCore so behaviour stays
// identical regardless of how the app is launched.
//
// `@main` lives on a struct (not in a file called main.swift) so we can
// mark the entry point `@MainActor` and satisfy `AppDelegate`'s actor
// isolation requirement.
@main
struct PTTVoiceLauncher {
    @MainActor
    static func main() {
        // Must run before AppDelegate (and thus AppModel / LocalASRClient)
        // is constructed so HF_ENDPOINT is in place when HubApi initializes.
        HFConfig.configure(source: HFConfig.persistedSource())
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
