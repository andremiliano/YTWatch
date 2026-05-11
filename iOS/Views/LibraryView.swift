import SwiftUI

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @ObservedObject private var client = YTMusicClient.shared
    @State private var appeared = false

    private var libraryTitle: String {
        if let name = client.userDisplayName, !name.isEmpty {
            let first = name.components(separatedBy: " ").first ?? name
            return "\(first)'s Library"
        }
        return "Library"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                if store.playlists.isEmpty && !store.isLoading {
                    EmptyLibraryView()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(store.playlists.enumerated()), id: \.element.id) { i, playlist in
                                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                                    PlaylistRow(playlist: playlist)
                                        .opacity(appeared ? 1 : 0)
                                        .offset(y: appeared ? 0 : 12)
                                        .animation(
                                            .spring(response: 0.5, dampingFraction: 0.8)
                                            .delay(Double(i) * 0.04),
                                            value: appeared
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle(libraryTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView()
                            .tint(Color.ytRed)
                    } else {
                        Button(action: { Task { await store.refresh() } }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.appDim)
                        }
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            )) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .task { if store.playlists.isEmpty { await store.refresh() } }
        .onAppear {
            withAnimation { appeared = true }
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @State private var pressed = false

    private var downloadedCount: Int {
        playlist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }
    private var syncedCount: Int {
        playlist.tracks.filter { sync.syncedTrackIds.contains($0.videoId) }.count
    }
    private var downloadFraction: Double {
        guard playlist.trackCount > 0 else { return 0 }
        return Double(downloadedCount) / Double(playlist.trackCount)
    }

    var body: some View {
        HStack(spacing: 14) {
            ThumbnailView(url: playlist.thumbnailURL, size: 58, cornerRadius: 10)
                .overlay(alignment: .bottomTrailing) {
                    if syncedCount == playlist.trackCount && playlist.trackCount > 0 {
                        Image(systemName: "applewatch")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(3)
                            .background(Color.ytRed)
                            .clipShape(Circle())
                            .offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(playlist.trackCount) tracks")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.appFaint)

                // Download progress bar
                if downloadedCount > 0 && downloadedCount < playlist.trackCount {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.appGhost).frame(height: 2)
                            Capsule()
                                .fill(Color.ytRed.opacity(0.8))
                                .frame(width: geo.size.width * downloadFraction, height: 2)
                        }
                    }
                    .frame(height: 2)
                } else if downloadedCount == playlist.trackCount && playlist.trackCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.ytRed).frame(width: 5, height: 5)
                        Text("Downloaded")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.ytRed.opacity(0.8))
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
        .padding(.vertical, 2)
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Color.appGhost)
            Text("No Playlists")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.appDim)
            Text("Pull to refresh or check your connection.")
                .font(.system(size: 13))
                .foregroundStyle(Color.appFaint)
                .multilineTextAlignment(.center)
        }
    }
}
