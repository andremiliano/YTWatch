import SwiftUI

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.playlists.isEmpty && !store.isLoading {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "music.note.list",
                        description: Text("Pull to refresh or check your connection.")
                    )
                } else {
                    List(store.playlists) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Button(action: { Task { await store.refresh() } }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { await store.refresh() }
            .task { if store.playlists.isEmpty { await store.refresh() } }
            .alert("Error", isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            )) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var downloadedCount: Int {
        playlist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }
    private var syncedCount: Int {
        playlist.tracks.filter { sync.syncedTrackIds.contains($0.videoId) }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: playlist.thumbnailURL ?? "")) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title).fontWeight(.medium)
                Text("\(playlist.trackCount) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if downloadedCount > 0 {
                        Label("\(downloadedCount)", systemImage: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    if syncedCount > 0 {
                        Label("\(syncedCount)", systemImage: "applewatch")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
