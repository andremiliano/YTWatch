import Foundation
import WatchConnectivity

// Receives audio files and playlist metadata from the iPhone companion app.
@MainActor
final class WatchFileReceiver: NSObject, ObservableObject {

    static let shared = WatchFileReceiver()

    @Published var playlists: [Playlist] = []
    @Published var receivingCount = 0

    private let fm = FileManager.default

    static var audioDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
    }

    private static var fm: FileManager { .default }

    override init() {
        super.init()
        createAudioDirectory()
        loadPlaylistsFromDisk()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Public

    func audioURL(for videoId: String) -> URL? {
        let url = Self.audioDirectory.appendingPathComponent("\(videoId).m4a")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func isAvailable(_ videoId: String) -> Bool {
        audioURL(for: videoId) != nil
    }

    func availableTrackIds() -> Set<String> {
        guard let files = try? fm.contentsOfDirectory(at: Self.audioDirectory, includingPropertiesForKeys: nil) else { return [] }
        return Set(files.filter { $0.pathExtension == "m4a" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    // Filter playlists to only tracks actually on device
    var availablePlaylists: [Playlist] {
        let ids = availableTrackIds()
        return playlists.compactMap { playlist -> Playlist? in
            var p = playlist
            p.tracks = playlist.tracks.filter { ids.contains($0.videoId) }
            return p.tracks.isEmpty ? nil : p
        }
    }

    // MARK: - Storage

    var usedBytes: Int64 {
        guard let files = try? fm.contentsOfDirectory(at: Self.audioDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + Int64(size)
        }
    }

    var usedMB: Double { Double(usedBytes) / 1_000_000 }

    // MARK: - Private

    private func createAudioDirectory() {
        try? fm.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
    }

    private func loadPlaylistsFromDisk() {
        let url = cacheURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
    }

    private func savePlaylistsToDisk() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: cacheURL())
    }

    private func cacheURL() -> URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlists_cache.json")
    }

    private func upsertPlaylist(_ playlist: Playlist) {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
        savePlaylistsToDisk()
    }
}

// MARK: - WCSessionDelegate

extension WatchFileReceiver: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    // Receive audio file
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor in
            self.receivingCount += 1
            defer { self.receivingCount = max(0, self.receivingCount - 1) }

            guard let meta = file.metadata,
                  let metaData = try? JSONSerialization.data(withJSONObject: meta),
                  let transfer = try? JSONDecoder().decode(TrackTransferMetadata.self, from: metaData) else { return }

            let destURL = Self.audioDirectory.appendingPathComponent("\(transfer.track.videoId).m4a")
            try? self.fm.removeItem(at: destURL)
            try? self.fm.copyItem(at: file.fileURL, to: destURL)

            // Update playlist metadata
            if var playlist = self.playlists.first(where: { $0.id == transfer.playlistId }) {
                if !playlist.tracks.contains(where: { $0.videoId == transfer.track.videoId }) {
                    playlist.tracks.append(transfer.track)
                    playlist.tracks.sort { $0.id < $1.id }
                }
                self.upsertPlaylist(playlist)
            } else {
                // New playlist — create it
                let newPlaylist = Playlist(
                    id: transfer.playlistId,
                    title: transfer.playlistTitle,
                    thumbnailURL: nil,
                    tracks: [transfer.track]
                )
                self.upsertPlaylist(newPlaylist)
            }
        }
    }

    // Receive playlist metadata context update
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            guard let typeStr = applicationContext[WatchMessageKey.type.rawValue] as? String,
                  let type = WatchMessageType(rawValue: typeStr),
                  type == .playlistIndex,
                  let b64 = applicationContext[WatchMessageKey.payload.rawValue] as? String,
                  let data = Data(base64Encoded: b64),
                  let playlist = try? JSONDecoder().decode(Playlist.self, from: data) else { return }

            self.upsertPlaylist(playlist)
        }
    }
}
