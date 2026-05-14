import Foundation

@MainActor
final class LibraryStore: ObservableObject {

    static let shared = LibraryStore()

    @Published var playlists: [Playlist] = []
    @Published var librarySongs: [Track] = []
    @Published var isLoading = false
    @Published var error: String?

    private let cacheURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library_cache.json")

    init() { loadFromDisk() }

    func refresh() async {
        guard YTMusicClient.shared.isAuthenticated, !isLoading else { return }
        isLoading = true
        error = nil
        async let songsTask: Void = fetchLibrarySongs()
        do {
            let shells = try await YTMusicClient.shared.fetchLibraryPlaylists()
            playlists = shells.map { shell in
                if let cached = playlists.first(where: { $0.id == shell.id }), !cached.tracks.isEmpty {
                    var merged = shell
                    merged.tracks = cached.tracks
                    return merged
                }
                return shell
            }
            isLoading = false
            await fetchTracksInBackground(for: shells)
        } catch is CancellationError {
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
        _ = await songsTask
    }

    private func fetchLibrarySongs() async {
        librarySongs = (try? await YTMusicClient.shared.fetchLibrarySongs()) ?? []
    }

    private func fetchTracksInBackground(for shells: [Playlist]) async {
        var updated = playlists
        let maxConcurrent = 4
        var playlistsToAutoUpdate: [(Playlist, [Track])] = []

        await withTaskGroup(of: (String, [Track]).self) { group in
            for (i, playlist) in shells.enumerated() {
                if i >= maxConcurrent { _ = await group.next() }
                group.addTask {
                    let tracks = (try? await YTMusicClient.shared.fetchPlaylistTracks(playlistId: playlist.id)) ?? []
                    return (playlist.id, tracks)
                }
            }
            for await (id, tracks) in group {
                if let idx = updated.firstIndex(where: { $0.id == id }) {
                    let oldTracks = updated[idx].tracks
                    updated[idx].tracks = tracks

                    let downloader = AudioDownloader.shared
                    let hasDownloads = oldTracks.contains { downloader.isDownloaded($0.videoId) }
                    if hasDownloads {
                        let newTracks = tracks.filter { t in
                            !oldTracks.contains(where: { $0.videoId == t.videoId }) && !downloader.isDownloaded(t.videoId)
                        }
                        if !newTracks.isEmpty {
                            playlistsToAutoUpdate.append((updated[idx], newTracks))
                        }
                    }
                }
            }
        }
        // Single update after all tracks fetched — no mid-loop UI churn
        playlists = updated.sorted { $0.title < $1.title }
        saveToDisk()

        for (playlist, newTracks) in playlistsToAutoUpdate {
            await autoDownloadNewTracks(newTracks, playlist: playlist)
        }
    }

    private func autoDownloadNewTracks(_ tracks: [Track], playlist: Playlist) async {
        print("[Library] Auto-downloading \(tracks.count) new tracks for \(playlist.title)")

        await withTaskGroup(of: Void.self) { group in
            for track in tracks {
                group.addTask {
                    _ = try? await AudioDownloader.shared.download(track: track, playlistId: playlist.id, playlistTitle: playlist.title)
                }
            }
        }

        if WatchSyncManager.shared.isAvailable {
            WatchSyncManager.shared.syncPlaylist(playlist)
        }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: cacheURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
    }
}
