import Foundation

// Caches fetched playlists to disk so they survive app restarts.
@MainActor
final class LibraryStore: ObservableObject {

    static let shared = LibraryStore()

    @Published var playlists: [Playlist] = []
    @Published var isLoading = false
    @Published var error: String?

    private let cacheURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library_cache.json")

    init() { loadFromDisk() }

    func refresh() async {
        guard YTMusicClient.shared.isAuthenticated else { return }
        isLoading = true
        error = nil
        do {
            var fetched = try await YTMusicClient.shared.fetchLibraryPlaylists()
            // Fetch tracks for each playlist in parallel (batched)
            fetched = try await withThrowingTaskGroup(of: Playlist.self) { group in
                for playlist in fetched {
                    group.addTask {
                        var p = playlist
                        p.tracks = (try? await YTMusicClient.shared.fetchPlaylistTracks(playlistId: p.id)) ?? []
                        return p
                    }
                }
                var result: [Playlist] = []
                for try await p in group { result.append(p) }
                return result.sorted { $0.title < $1.title }
            }
            playlists = fetched
            saveToDisk()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
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
