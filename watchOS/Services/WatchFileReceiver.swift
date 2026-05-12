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

    static var thumbnailDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private static var fm: FileManager { .default }

    override init() {
        super.init()
        createDirectories()
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

    func thumbnailURL(for videoId: String) -> URL? {
        let url = Self.thumbnailDirectory.appendingPathComponent("\(videoId).jpg")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func deletePlaylist(_ playlist: Playlist) {
        // Collect track IDs used by OTHER playlists so we don't delete shared files
        let otherTrackIds = Set(playlists.filter { $0.id != playlist.id }.flatMap { $0.tracks.map(\.videoId) })
        for track in playlist.tracks where !otherTrackIds.contains(track.videoId) {
            let audio = Self.audioDirectory.appendingPathComponent("\(track.videoId).m4a")
            let thumb = Self.thumbnailDirectory.appendingPathComponent("\(track.videoId).jpg")
            try? fm.removeItem(at: audio)
            try? fm.removeItem(at: thumb)
        }
        playlists.removeAll { $0.id == playlist.id }
        savePlaylistsToDisk()
    }

    func isAvailable(_ videoId: String) -> Bool {
        audioURL(for: videoId) != nil
    }

    func rescanFiles() {
        let ids = availableTrackIds()
        let hadTracks = !playlists.flatMap(\.tracks).isEmpty
        objectWillChange.send()
        if !hadTracks {
            loadPlaylistsFromDisk()
        }
        _ = ids
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

    private func createDirectories() {
        try? fm.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.thumbnailDirectory, withIntermediateDirectories: true)
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

    func deleteTrack(videoId: String) {
        let audio = Self.audioDirectory.appendingPathComponent("\(videoId).m4a")
        let thumb = Self.thumbnailDirectory.appendingPathComponent("\(videoId).jpg")
        try? fm.removeItem(at: audio)
        try? fm.removeItem(at: thumb)
        for i in playlists.indices {
            playlists[i].tracks.removeAll { $0.videoId == videoId }
        }
        playlists.removeAll { $0.tracks.isEmpty }
        savePlaylistsToDisk()
    }

    func cleanupOrphanedFiles() {
        let allTrackIds = Set(playlists.flatMap { $0.tracks.map(\.videoId) })
        let onDisk = availableTrackIds()
        let orphans = onDisk.subtracting(allTrackIds)
        for id in orphans {
            let audioFile = Self.audioDirectory.appendingPathComponent("\(id).m4a")
            let thumbFile = Self.thumbnailDirectory.appendingPathComponent("\(id).jpg")
            try? fm.removeItem(at: audioFile)
            try? fm.removeItem(at: thumbFile)
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchFileReceiver: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    // Receive audio or thumbnail file
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fileURL = file.fileURL
        let metaData: Data? = file.metadata.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let isThumbnail = (file.metadata?["isThumbnail"] as? Bool) == true

        Task { @MainActor in
            self.receivingCount += 1
            defer { self.receivingCount = max(0, self.receivingCount - 1) }

            guard let metaData,
                  let transfer = try? JSONDecoder().decode(TrackTransferMetadata.self, from: metaData) else { return }

            if isThumbnail {
                let thumbDest = Self.thumbnailDirectory.appendingPathComponent("\(transfer.track.videoId).jpg")
                try? self.fm.removeItem(at: thumbDest)
                try? self.fm.copyItem(at: fileURL, to: thumbDest)
                return
            }

            let destURL = Self.audioDirectory.appendingPathComponent("\(transfer.track.videoId).m4a")
            try? self.fm.removeItem(at: destURL)
            try? self.fm.copyItem(at: fileURL, to: destURL)

            if var playlist = self.playlists.first(where: { $0.id == transfer.playlistId }) {
                if !playlist.tracks.contains(where: { $0.videoId == transfer.track.videoId }) {
                    let idx = transfer.indexInPlaylist
                    if idx >= 0 && idx <= playlist.tracks.count {
                        playlist.tracks.insert(transfer.track, at: min(idx, playlist.tracks.count))
                    } else {
                        playlist.tracks.append(transfer.track)
                    }
                }
                self.upsertPlaylist(playlist)
            } else {
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

    nonisolated func session(_ session: WCSession, didReceive message: [String: Any]) {
        handleIncomingMessage(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncomingMessage(userInfo)
    }

    private nonisolated func handleIncomingMessage(_ msg: [String: Any]) {
        let typeStr = msg[WatchMessageKey.type.rawValue] as? String
        let videoId = msg["videoId"] as? String
        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }
            if type == .deleteTrack, let videoId {
                self.deleteTrack(videoId: videoId)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let typeStr = applicationContext[WatchMessageKey.type.rawValue] as? String
        let b64 = applicationContext[WatchMessageKey.payload.rawValue] as? String
        let videoId = applicationContext["videoId"] as? String

        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }

            switch type {
            case .playlistIndex:
                guard let b64, let data = Data(base64Encoded: b64),
                      let playlist = try? JSONDecoder().decode(Playlist.self, from: data) else { return }
                self.upsertPlaylist(playlist)
                self.cleanupOrphanedFiles()
            case .deleteTrack:
                if let videoId { self.deleteTrack(videoId: videoId) }
            default:
                break
            }
        }
    }
}
