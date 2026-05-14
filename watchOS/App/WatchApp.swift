import SwiftUI

@main
struct YTWatchWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = WatchFileReceiver.shared  // activate WCSession
        WatchPlayer.shared.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            PlaylistListView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Re-sync sleep timer from absolute target after background
                WatchPlayer.shared.refreshSleepTimer()
            }
        }
    }
}
