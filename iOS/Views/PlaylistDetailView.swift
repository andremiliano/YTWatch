import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @State private var tracks: [Track] = []
    @State private var isLoadingTracks = false
    @State private var isDownloadingAll = false
    @State private var isSyncing = false
    @State private var appeared = false

    private var downloadedCount: Int {
        tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }
    private var allDownloaded: Bool { downloadedCount == tracks.count && !tracks.isEmpty }
    private var allSynced: Bool { tracks.allSatisfy { sync.syncedTrackIds.contains($0.videoId) } }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    PlaylistHeroHeader(
                        playlist: playlist,
                        trackCount: tracks.count,
                        downloadedCount: downloadedCount
                    )
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -8)

                    if isLoadingTracks {
                        ProgressView()
                            .tint(Color.ytRed)
                            .padding(.top, 48)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                                TrackRow(track: track)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 8)
                                    .animation(
                                        .spring(response: 0.45, dampingFraction: 0.82)
                                            .delay(0.1 + Double(i) * 0.025),
                                        value: appeared
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                    }
                }
            }

            if !isLoadingTracks {
                FloatingActionBar(
                    trackCount: tracks.count,
                    allDownloaded: allDownloaded,
                    allSynced: allSynced,
                    isDownloadingAll: isDownloadingAll,
                    isSyncing: isSyncing,
                    downloadedCount: downloadedCount,
                    onDownload: downloadAll,
                    onSync: syncToWatch
                )
                .opacity(appeared ? 1 : 0)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { appeared = true }
        }
        .task {
            if !playlist.tracks.isEmpty {
                tracks = playlist.tracks
            } else {
                isLoadingTracks = true
                tracks = (try? await YTMusicClient.shared.fetchPlaylistTracks(playlistId: playlist.id)) ?? []
                isLoadingTracks = false
            }
        }
    }

    private func downloadAll() {
        isDownloadingAll = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                for track in tracks {
                    guard !downloader.isDownloaded(track.videoId) else { continue }
                    group.addTask { _ = try? await AudioDownloader.shared.download(track: track) }
                }
            }
            isDownloadingAll = false
        }
    }

    private func syncToWatch() {
        guard sync.isAvailable else { return }
        isSyncing = true
        Task {
            var p = playlist
            p.tracks = tracks
            await sync.syncPlaylist(p)
            isSyncing = false
        }
    }
}

// MARK: - Hero Header

private struct PlaylistHeroHeader: View {
    let playlist: Playlist
    let trackCount: Int
    let downloadedCount: Int

    var body: some View {
        VStack(spacing: 16) {
            ThumbnailView(url: playlist.thumbnailURL, size: 120, cornerRadius: 16)
                .shadow(color: .black.opacity(0.6), radius: 24, y: 12)

            VStack(spacing: 6) {
                Text(playlist.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    if trackCount > 0 {
                        Label("\(trackCount) tracks", systemImage: "music.note")
                    }
                    if downloadedCount > 0 {
                        Text("·")
                        Label("\(downloadedCount) downloaded", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.ytRed.opacity(0.8))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.appFaint)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }
}

// MARK: - Floating Action Bar

private struct FloatingActionBar: View {
    let trackCount: Int
    let allDownloaded: Bool
    let allSynced: Bool
    let isDownloadingAll: Bool
    let isSyncing: Bool
    let downloadedCount: Int
    let onDownload: () -> Void
    let onSync: () -> Void

    @ObservedObject private var sync = WatchSyncManager.shared

    var body: some View {
        VStack(spacing: 10) {
            // Progress when downloading
            if isDownloadingAll {
                let progress = Double(downloadedCount) / Double(max(trackCount, 1))
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.appGhost)
                            Capsule()
                                .fill(Color.ytRed)
                                .frame(width: geo.size.width * progress)
                                .animation(.spring(response: 0.4), value: progress)
                        }
                    }
                    .frame(height: 3)

                    Text("\(downloadedCount) of \(trackCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appFaint)
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 10) {
                Button(action: onDownload) {
                    HStack(spacing: 8) {
                        if isDownloadingAll {
                            ProgressView().tint(.white).scaleEffect(0.75)
                        } else {
                            Image(systemName: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 15))
                        }
                        Text(allDownloaded ? "Downloaded" : "Download")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(allDownloaded ? Color.appDim : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(allDownloaded ? Color.appSurface : Color.ytRed)
                    .clipShape(Capsule())
                }
                .disabled(allDownloaded || isDownloadingAll)

                Button(action: onSync) {
                    HStack(spacing: 8) {
                        if isSyncing {
                            ProgressView().tint(.white).scaleEffect(0.75)
                        } else {
                            Image(systemName: allSynced ? "applewatch.radiowaves.left.and.right" : "applewatch")
                                .font(.system(size: 15))
                        }
                        Text(allSynced ? "Synced" : "Sync")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(allSynced ? Color.appDim : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(allSynced ? Color.appSurface : Color.appElevated)
                    .clipShape(Capsule())
                }
                .disabled(!sync.isAvailable || allSynced || downloadedCount == 0 || isSyncing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color.appBg.opacity(0), Color.appBg, Color.appBg],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Track Row

struct TrackRow: View {
    let track: Track
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var progress: Double? { downloader.downloadProgress[track.videoId] }
    private var isDownloaded: Bool { downloader.isDownloaded(track.videoId) }
    private var isSynced: Bool { sync.syncedTrackIds.contains(track.videoId) }
    private var isTransferring: Bool { sync.transferringTrackIds.contains(track.videoId) }

    var body: some View {
        HStack(spacing: 12) {
            // Status column
            ZStack {
                if isTransferring {
                    ProgressView().tint(Color.appFaint).scaleEffect(0.7)
                } else if isSynced {
                    Image(systemName: "applewatch")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.ytRed)
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appDim.opacity(0.6))
                } else if let p = progress {
                    ZStack {
                        Circle().stroke(Color.appGhost, lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(Color.ytRed, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                } else {
                    Circle()
                        .fill(Color.appGhost)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 20)

            // Track info
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appFaint)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appGhost)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .contextMenu {
            if !isDownloaded {
                Button(action: { Task { _ = try? await AudioDownloader.shared.download(track: track) } }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            } else {
                Button(role: .destructive, action: { downloader.deleteDownload(videoId: track.videoId) }) {
                    Label("Remove Download", systemImage: "trash")
                }
            }
        }
    }
}
