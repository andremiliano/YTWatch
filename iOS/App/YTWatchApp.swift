import SwiftUI

@main
struct YTWatchApp: App {
    @ObservedObject private var client = YTMusicClient.shared

    init() {
        YTMusicClient.shared.loadSavedCookies()
        _ = WatchSyncManager.shared  // activate WCSession early
    }

    var body: some Scene {
        WindowGroup {
            if client.isAuthenticated {
                ContentView()
            } else {
                AuthView()
            }
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
