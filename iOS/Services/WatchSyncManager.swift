import Foundation
import WatchConnectivity

// Manages transferring downloaded audio files and metadata to the Apple Watch.
@MainActor
final class WatchSyncManager: NSObject, ObservableObject {

    static let shared = WatchSyncManager()

    @Published var isWatchReachable = false
    @Published var syncedTrackIds: Set<String> = []
    @Published var transferringTrackIds: Set<String> = []
    @Published var syncedPlaylists: [Playlist] = []

    private var session: WCSession?
    private var pendingTransfers: [String: WCSessionFileTransfer] = [:]

    override init() {
        super.init()
        loadSyncState()
        if WCSession.isSupported() {
            let s = WCSession.default
            s.delegate = self
            s.activate()
            session = s
        }
    }

    // MARK: - Public

    var isAvailable: Bool {
        session?.activationState == .activated && session?.isPaired == true
    }

    func syncPlaylist(_ playlist: Playlist) async {
        guard isAvailable else { return }

        // Push metadata index first so watch knows what's coming
        pushPlaylistIndex(playlist)

        // Transfer each downloaded track
        for track in playlist.tracks {
            guard !syncedTrackIds.contains(track.videoId) else { continue }
            guard let localURL = AudioDownloader.shared.localURL(for: track.videoId) else { continue }
            await transferTrack(track, from: localURL, playlistId: playlist.id, playlistTitle: playlist.title, index: playlist.tracks.firstIndex(of: track) ?? 0)
        }
    }

    func removeFromWatch(videoId: String) {
        syncedTrackIds.remove(videoId)
        saveSyncState()
        // The watch deletes its own copy when it receives the updated index
        pushSyncState()
    }

    // MARK: - Private

    private func transferTrack(_ track: Track, from url: URL, playlistId: String, playlistTitle: String, index: Int) async {
        guard let session else { return }
        transferringTrackIds.insert(track.videoId)

        let meta = TrackTransferMetadata(track: track, playlistId: playlistId, playlistTitle: playlistTitle, indexInPlaylist: index)
        guard let metaData = try? JSONEncoder().encode(meta),
              let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
            transferringTrackIds.remove(track.videoId)
            return
        }

        let transfer = session.transferFile(url, metadata: metaDict)
        pendingTransfers[track.videoId] = transfer
    }

    private func pushPlaylistIndex(_ playlist: Playlist) {
        guard let session, session.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(playlist) else { return }
        let context: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.playlistIndex.rawValue,
            WatchMessageKey.payload.rawValue: data.base64EncodedString()
        ]
        try? session.updateApplicationContext(context)
    }

    private func pushSyncState() {
        guard let session, session.activationState == .activated else { return }
        let ids = Array(syncedTrackIds)
        try? session.updateApplicationContext(["syncedTrackIds": ids])
    }

    private func saveSyncState() {
        let ids = Array(syncedTrackIds)
        UserDefaults.standard.set(ids, forKey: "syncedTrackIds")

        if let data = try? JSONEncoder().encode(syncedPlaylists) {
            UserDefaults.standard.set(data, forKey: "syncedPlaylists")
        }
    }

    private func loadSyncState() {
        if let ids = UserDefaults.standard.array(forKey: "syncedTrackIds") as? [String] {
            syncedTrackIds = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: "syncedPlaylists"),
           let playlists = try? JSONDecoder().decode([Playlist].self, from: data) {
            syncedPlaylists = playlists
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncManager: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in self.isWatchReachable = reachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isWatchReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // Use ObjectIdentifier (Sendable) to match the transfer on the main actor
        let transferId = ObjectIdentifier(fileTransfer)
        let succeeded = error == nil
        Task { @MainActor in
            if let videoId = self.pendingTransfers.first(where: { ObjectIdentifier($0.value) == transferId })?.key {
                self.pendingTransfers.removeValue(forKey: videoId)
                self.transferringTrackIds.remove(videoId)
                if succeeded {
                    self.syncedTrackIds.insert(videoId)
                    self.saveSyncState()
                }
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
