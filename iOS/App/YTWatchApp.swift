import SwiftUI

@main
struct YTWatchApp: App {
    @ObservedObject private var client = YTMusicClient.shared

    init() {
        YTMusicClient.shared.loadSavedCookies()
        _ = WatchSyncManager.shared

        // Force dark tab bar / nav bar appearance globally
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(red: 0.047, green: 0.047, blue: 0.047, alpha: 1)
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(red: 0.047, green: 0.047, blue: 0.047, alpha: 1)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
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
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

            ForYouView()
                .tabItem {
                    Label("For You", systemImage: "wand.and.stars")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .preferredColorScheme(.dark)
        .tint(Color.ytRed)
    }
}
