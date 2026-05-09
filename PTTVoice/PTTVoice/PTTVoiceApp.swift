import SwiftUI
import PTTMacVoiceCore

@main
struct PTTVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Must run before the AppDelegate adaptor instantiates AppDelegate
        // (and thus AppModel / LocalASRClient) so HF_ENDPOINT is in place
        // when HubApi initializes. The persisted DownloadSource picks the
        // endpoint; ModelScope falls back to a harmless default since it
        // never hits HubApi.
        HFConfig.configure(source: HFConfig.persistedSource())
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
