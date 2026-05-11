import SwiftUI

struct SettingsView: View {
    @ObservedObject private var client = YTMusicClient.shared
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            Form {

                // Watch status
                Section("Apple Watch") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Label(
                            sync.isAvailable ? (sync.isWatchReachable ? "Connected" : "Paired") : "Unavailable",
                            systemImage: sync.isAvailable ? "applewatch" : "applewatch.slash"
                        )
                        .foregroundStyle(sync.isAvailable ? .green : .secondary)
                        .font(.caption)
                    }
                    HStack {
                        Text("Synced Tracks")
                        Spacer()
                        Text("\(sync.syncedTrackIds.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                // Account
                Section("Account") {
                    HStack {
                        Text("YouTube Music")
                        Spacer()
                        Text(client.isAuthenticated ? "Signed In" : "Not Signed In")
                            .foregroundStyle(client.isAuthenticated ? .green : .secondary)
                    }
                    if client.isAuthenticated {
                        Button("Sign Out", role: .destructive) {
                            showLogoutConfirm = true
                        }
                    }
                }

                // Storage
                Section("Storage") {
                    let count = AudioDownloader.shared.downloadedTracks.count
                    HStack {
                        Text("Downloaded Tracks")
                        Spacer()
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear All Downloads", role: .destructive) {
                        for id in Array(downloader.downloadedTracks.keys) {
                            downloader.deleteDownload(videoId: id)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign Out?", isPresented: $showLogoutConfirm) {
                Button("Sign Out", role: .destructive) { client.logout() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

}
