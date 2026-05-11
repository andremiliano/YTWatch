import SwiftUI

@main
struct YTWatchWatchApp: App {
    init() {
        _ = WatchFileReceiver.shared  // activate WCSession
        WatchPlayer.shared.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            PlaylistListView()
        }
    }
}
