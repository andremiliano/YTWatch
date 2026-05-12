import Foundation
import WatchConnectivity
import UserNotifications

@MainActor
final class WatchSyncManager: NSObject, ObservableObject {

    static let shared = WatchSyncManager()

    @Published var isWatchReachable = false
    @Published var syncedTrackIds: Set<String> = []
    @Published var transferringTrackIds: Set<String> = []
    @Published var syncedPlaylists: [Playlist] = []
    @Published var pendingSyncCount = 0

    private var session: WCSession?
    private var pendingTransfers: [String: WCSessionFileTransfer] = [:]
    private var pendingSyncQueue: [PendingSyncItem] = []
    private var hadActiveSyncs = false

    struct PendingSyncItem: Codable {
        let videoId: String
        let title: String
        let artist: String
        let album: String?
        let durationSeconds: Int
        let thumbnailURL: String?
        let playlistId: String
        let playlistTitle: String
    }

    override init() {
        super.init()
        loadSyncState()
        loadPendingQueue()
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

    func queueTrackForSync(_ track: Track, fileURL: URL, playlistId: String, playlistTitle: String) {
        guard !syncedTrackIds.contains(track.videoId) else { return }
        guard !transferringTrackIds.contains(track.videoId) else { return }

        let item = PendingSyncItem(
            videoId: track.videoId, title: track.title, artist: track.artist,
            album: track.album, durationSeconds: track.durationSeconds,
            thumbnailURL: track.thumbnailURL, playlistId: playlistId, playlistTitle: playlistTitle
        )

        if !pendingSyncQueue.contains(where: { $0.videoId == track.videoId }) {
            pendingSyncQueue.append(item)
            savePendingQueue()
        }

        if isAvailable {
            Task { @MainActor in self.drainPendingQueue() }
        }
    }

    func syncUnsyncedDownloads() {
        let downloaded = AudioDownloader.shared.downloadedTracks
        for (videoId, _) in downloaded {
            guard !syncedTrackIds.contains(videoId) else { continue }
            guard !transferringTrackIds.contains(videoId) else { continue }
            guard !pendingSyncQueue.contains(where: { $0.videoId == videoId }) else { continue }

            if let meta = AudioDownloader.shared.trackMetadata[videoId] {
                let item = PendingSyncItem(
                    videoId: videoId, title: meta.title, artist: meta.artist,
                    album: nil, durationSeconds: 0, thumbnailURL: meta.thumbnailURL,
                    playlistId: "library", playlistTitle: "Downloads"
                )
                pendingSyncQueue.append(item)
            }
        }
        savePendingQueue()
        if isAvailable {
            Task { @MainActor in self.drainPendingQueue() }
        }
    }

    func syncPlaylist(_ playlist: Playlist) {
        guard isAvailable else { return }

        pushPlaylistIndex(playlist)

        var toSync: [(track: Track, url: URL, index: Int)] = []
        for (i, track) in playlist.tracks.enumerated() {
            guard !syncedTrackIds.contains(track.videoId) else { continue }
            guard !transferringTrackIds.contains(track.videoId) else { continue }
            guard let localURL = AudioDownloader.shared.localURL(for: track.videoId) else { continue }
            toSync.append((track, localURL, i))
        }
        guard !toSync.isEmpty else { return }

        for item in toSync {
            transferringTrackIds.insert(item.track.videoId)
        }
        hadActiveSyncs = true

        let pid = playlist.id
        let ptitle = playlist.title
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for item in toSync {
                    group.addTask {
                        if let thumbStr = item.track.thumbnailURL, let thumbURL = URL(string: thumbStr) {
                            await Self.downloadThumbnailBackground(from: thumbURL, videoId: item.track.videoId)
                        }
                    }
                }
            }
            await MainActor.run {
                self.queueTransfers(toSync, playlistId: pid, playlistTitle: ptitle)
            }
        }
    }

    func removeFromWatch(videoId: String) {
        syncedTrackIds.remove(videoId)
        pendingSyncQueue.removeAll { $0.videoId == videoId }
        savePendingQueue()
        saveSyncState()
        guard let session, session.activationState == .activated else { return }
        let msg: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.deleteTrack.rawValue,
            "videoId": videoId
        ]
        session.transferUserInfo(msg)
    }

    // MARK: - Private

    private func drainPendingQueue() {
        guard isAvailable else { return }
        var remaining: [PendingSyncItem] = []
        var toSync: [(track: Track, url: URL, playlistId: String, playlistTitle: String)] = []

        for item in pendingSyncQueue {
            guard !syncedTrackIds.contains(item.videoId) else { continue }
            guard !transferringTrackIds.contains(item.videoId) else {
                remaining.append(item)
                continue
            }
            guard let localURL = AudioDownloader.shared.localURL(for: item.videoId) else {
                remaining.append(item)
                continue
            }
            let track = Track(
                id: item.videoId, videoId: item.videoId, title: item.title,
                artist: item.artist, album: item.album,
                durationSeconds: item.durationSeconds, thumbnailURL: item.thumbnailURL
            )
            toSync.append((track, localURL, item.playlistId, item.playlistTitle))
        }

        pendingSyncQueue = remaining
        savePendingQueue()

        guard !toSync.isEmpty else { return }

        for item in toSync {
            transferringTrackIds.insert(item.track.videoId)
        }
        hadActiveSyncs = true

        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for item in toSync {
                    group.addTask {
                        if let thumbStr = item.track.thumbnailURL, let thumbURL = URL(string: thumbStr) {
                            await Self.downloadThumbnailBackground(from: thumbURL, videoId: item.track.videoId)
                        }
                    }
                }
            }
            await MainActor.run { [toSync] in
                guard let session = self.session else { return }
                for item in toSync {
                    let meta = TrackTransferMetadata(track: item.track, playlistId: item.playlistId, playlistTitle: item.playlistTitle, indexInPlaylist: 0)
                    guard let metaData = try? JSONEncoder().encode(meta),
                          let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
                        self.transferringTrackIds.remove(item.track.videoId)
                        continue
                    }
                    let transfer = session.transferFile(item.url, metadata: metaDict)
                    self.pendingTransfers[item.track.videoId] = transfer

                    let thumbDest = Self.thumbnailCacheDir.appendingPathComponent("\(item.track.videoId).jpg")
                    if FileManager.default.fileExists(atPath: thumbDest.path) {
                        var thumbMeta = metaDict
                        thumbMeta["isThumbnail"] = true
                        session.transferFile(thumbDest, metadata: thumbMeta)
                    }
                }
            }
        }
    }

    private func savePendingQueue() {
        pendingSyncCount = pendingSyncQueue.count
        if let data = try? JSONEncoder().encode(pendingSyncQueue) {
            UserDefaults.standard.set(data, forKey: "pendingSyncQueue")
        }
    }

    private func loadPendingQueue() {
        if let data = UserDefaults.standard.data(forKey: "pendingSyncQueue"),
           let items = try? JSONDecoder().decode([PendingSyncItem].self, from: data) {
            pendingSyncQueue = items
            pendingSyncCount = items.count
        }
    }

    private func queueTransfers(_ items: [(track: Track, url: URL, index: Int)], playlistId: String, playlistTitle: String) {
        guard let session else { return }
        for item in items {
            let meta = TrackTransferMetadata(track: item.track, playlistId: playlistId, playlistTitle: playlistTitle, indexInPlaylist: item.index)
            guard let metaData = try? JSONEncoder().encode(meta),
                  let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
                transferringTrackIds.remove(item.track.videoId)
                continue
            }

            let transfer = session.transferFile(item.url, metadata: metaDict)
            pendingTransfers[item.track.videoId] = transfer

            let thumbDest = Self.thumbnailCacheDir.appendingPathComponent("\(item.track.videoId).jpg")
            if FileManager.default.fileExists(atPath: thumbDest.path) {
                var thumbMeta = metaDict
                thumbMeta["isThumbnail"] = true
                session.transferFile(thumbDest, metadata: thumbMeta)
            }
        }
    }

    private func transferTrack(_ track: Track, from url: URL, playlistId: String, playlistTitle: String, index: Int) async {
        guard let session else { return }
        transferringTrackIds.insert(track.videoId)
        hadActiveSyncs = true

        if let thumbStr = track.thumbnailURL, let thumbURL = URL(string: thumbStr) {
            await Self.downloadThumbnailBackground(from: thumbURL, videoId: track.videoId)
        }

        let meta = TrackTransferMetadata(track: track, playlistId: playlistId, playlistTitle: playlistTitle, indexInPlaylist: index)
        guard let metaData = try? JSONEncoder().encode(meta),
              let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
            transferringTrackIds.remove(track.videoId)
            return
        }

        let transfer = session.transferFile(url, metadata: metaDict)
        pendingTransfers[track.videoId] = transfer

        let thumbDest = Self.thumbnailCacheDir.appendingPathComponent("\(track.videoId).jpg")
        if FileManager.default.fileExists(atPath: thumbDest.path) {
            var thumbMeta = metaDict
            thumbMeta["isThumbnail"] = true
            session.transferFile(thumbDest, metadata: thumbMeta)
        }
    }

    nonisolated private static var thumbnailCacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func downloadThumbnailBackground(from url: URL, videoId: String) async {
        let dest = thumbnailCacheDir.appendingPathComponent("\(videoId).jpg")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              !data.isEmpty else { return }
        try? data.write(to: dest)
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

    private func checkSyncCompletion() {
        guard hadActiveSyncs else { return }
        guard transferringTrackIds.isEmpty && pendingSyncQueue.isEmpty else { return }
        hadActiveSyncs = false
        let count = syncedTrackIds.count
        let content = UNMutableNotificationContent()
        content.title = "Watch Sync Complete"
        content.body = "\(count) tracks synced to Apple Watch"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "syncComplete", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        var outstandingVideoIds: [String] = []
        for transfer in session.outstandingFileTransfers {
            guard let meta = transfer.file.metadata,
                  (meta["isThumbnail"] as? Bool) != true,
                  let metaData = try? JSONSerialization.data(withJSONObject: meta),
                  let decoded = try? JSONDecoder().decode(TrackTransferMetadata.self, from: metaData) else { continue }
            outstandingVideoIds.append(decoded.track.videoId)
        }
        Task { @MainActor in
            self.isWatchReachable = reachable
            for videoId in outstandingVideoIds {
                self.transferringTrackIds.insert(videoId)
            }
            self.syncUnsyncedDownloads()
            self.drainPendingQueue()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isWatchReachable = reachable
            if reachable {
                self.drainPendingQueue()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // Extract videoId from transfer metadata — survives app relaunch unlike in-memory dict
        let meta = fileTransfer.file.metadata
        let isThumbnail = (meta?["isThumbnail"] as? Bool) == true
        var videoId: String?
        if let meta, let metaData = try? JSONSerialization.data(withJSONObject: meta),
           let decoded = try? JSONDecoder().decode(TrackTransferMetadata.self, from: metaData) {
            videoId = decoded.track.videoId
        }
        let succeeded = error == nil
        let errorMsg = error?.localizedDescription

        Task { @MainActor in
            guard let videoId, !isThumbnail else { return }
            self.pendingTransfers.removeValue(forKey: videoId)
            self.transferringTrackIds.remove(videoId)
            if succeeded {
                self.syncedTrackIds.insert(videoId)
                self.pendingSyncQueue.removeAll { $0.videoId == videoId }
                self.savePendingQueue()
                self.saveSyncState()
                print("[Sync] ✓ \(videoId)")
                self.checkSyncCompletion()
            } else {
                print("[Sync] ✗ \(videoId): \(errorMsg ?? "unknown")")
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
