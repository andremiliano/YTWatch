import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @State private var isDownloadingAll = false
    @State private var isSyncing = false

    private var allDownloaded: Bool {
        playlist.tracks.allSatisfy { downloader.isDownloaded($0.videoId) }
    }
    private var allSynced: Bool {
        playlist.tracks.allSatisfy { sync.syncedTrackIds.contains($0.videoId) }
    }
    private var downloadedCount: Int {
        playlist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }

    var body: some View {
        List {
            // Action bar
            Section {
                HStack(spacing: 12) {
                    Button(action: downloadAll) {
                        Label(
                            allDownloaded ? "Downloaded" : "Download All",
                            systemImage: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(allDownloaded || isDownloadingAll)
                    .tint(.blue)

                    Button(action: syncToWatch) {
                        Label(
                            allSynced ? "Synced" : "Sync to Watch",
                            systemImage: allSynced ? "applewatch.radiowaves.left.and.right" : "applewatch"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!sync.isAvailable || allSynced || downloadedCount == 0 || isSyncing)
                    .tint(.green)
                }
            }

            // Progress bar when downloading
            if isDownloadingAll {
                Section {
                    let progress = Double(downloadedCount) / Double(max(playlist.tracks.count, 1))
                    ProgressView(value: progress) {
                        Text("Downloading \(downloadedCount)/\(playlist.tracks.count)")
                            .font(.caption)
                    }
                }
            }

            // Track list
            Section("\(playlist.tracks.count) Tracks") {
                ForEach(playlist.tracks) { track in
                    TrackRow(track: track)
                }
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.large)
    }

    private func downloadAll() {
        isDownloadingAll = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                for track in playlist.tracks {
                    guard !downloader.isDownloaded(track.videoId) else { continue }
                    group.addTask {
                        _ = try? await AudioDownloader.shared.download(track: track)
                    }
                }
            }
            isDownloadingAll = false
        }
    }

    private func syncToWatch() {
        guard sync.isAvailable else { return }
        isSyncing = true
        Task {
            await sync.syncPlaylist(playlist)
            isSyncing = false
        }
    }
}

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
            // Status icon
            Group {
                if isTransferring {
                    ProgressView().frame(width: 20, height: 20)
                } else if isSynced {
                    Image(systemName: "applewatch")
                        .foregroundStyle(.green)
                        .frame(width: 20)
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                } else if let p = progress {
                    ProgressView(value: p).frame(width: 20, height: 20)
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
