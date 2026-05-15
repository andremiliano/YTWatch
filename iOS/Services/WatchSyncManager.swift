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
    @Published var isVerifying = false
    @Published var lastVerifyResult: VerifyResult?

    struct VerifyResult {
        let phoneThinksSynced: Int
        let actuallyOnWatch: Int
        let missingOnWatch: Int
        let resynced: Int
        let date: Date
    }

    private var session: WCSession?
    private var pendingTransfers: [String: WCSessionFileTransfer] = [:]
    private var pendingSyncQueue: [PendingSyncItem] = []
    private var hadActiveSyncs = false
    /// Tracks waiting for WiFi download result — keyed by videoId, task fires Bluetooth fallback after timeout
    private var wifiTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// VideoIds that failed WiFi download — forces Bluetooth path until next reachability change
    private var wifiFailedVideoIds: Set<String> = []

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
                    album: meta.album, durationSeconds: meta.durationSeconds,
                    thumbnailURL: meta.thumbnailURL,
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

    /// Asks Watch what tracks it actually has, fixes sync state, re-syncs missing tracks.
    func verifySyncAndRepair() {
        guard let session, session.activationState == .activated, session.isReachable else {
            print("[Sync] Watch not reachable for verify")
            return
        }
        guard !isVerifying else { return }
        isVerifying = true

        let msg: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.syncVerify.rawValue
        ]

        session.sendMessage(msg, replyHandler: { [weak self] reply in
            // Extract values on callback thread before crossing to MainActor
            let trackIds = reply["trackIds"] as? [String] ?? []
            Task { @MainActor in
                guard let self else { return }
                self.handleSyncInventory(watchTrackIds: trackIds)
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isVerifying = false
                print("[Sync] Verify failed: \(error.localizedDescription)")
            }
        })
    }

    /// Process Watch inventory response — fix state and re-sync missing tracks.
    private func handleSyncInventory(watchTrackIds: [String]) {
        let watchSet = Set(watchTrackIds)
        let phoneThinksSynced = syncedTrackIds.count

        // 1. Remove from syncedTrackIds anything Watch doesn't have
        let falseSynced = syncedTrackIds.subtracting(watchSet)
        for id in falseSynced {
            syncedTrackIds.remove(id)
        }

        // 2. Add to syncedTrackIds anything Watch has that we forgot about
        let untracked = watchSet.subtracting(syncedTrackIds)
        for id in untracked {
            syncedTrackIds.insert(id)
        }
        saveSyncState()

        // 3. Re-sync ALL missing tracks that we have locally
        //    Build a lookup: videoId → (playlistId, playlistTitle) from syncedPlaylists
        var trackPlaylistMap: [String: (playlistId: String, playlistTitle: String)] = [:]
        for playlist in syncedPlaylists {
            for track in playlist.tracks {
                trackPlaylistMap[track.videoId] = (playlist.id, playlist.title)
            }
        }

        var resynced = 0
        var alreadyQueued = Set(pendingSyncQueue.map(\.videoId))

        for videoId in falseSynced {
            // Must have the file on iPhone to re-sync
            guard AudioDownloader.shared.localURL(for: videoId) != nil else { continue }
            // Don't double-queue
            guard !alreadyQueued.contains(videoId) else { continue }
            guard !transferringTrackIds.contains(videoId) else { continue }

            // Get track metadata — try syncedPlaylists first, then trackMetadata fallback
            let item: PendingSyncItem
            if let playlistInfo = trackPlaylistMap[videoId],
               let track = syncedPlaylists
                .first(where: { $0.id == playlistInfo.playlistId })?
                .tracks.first(where: { $0.videoId == videoId }) {
                // Full Track data from synced playlist
                item = PendingSyncItem(
                    videoId: videoId, title: track.title, artist: track.artist,
                    album: track.album, durationSeconds: track.durationSeconds,
                    thumbnailURL: track.thumbnailURL,
                    playlistId: playlistInfo.playlistId, playlistTitle: playlistInfo.playlistTitle
                )
            } else if let meta = AudioDownloader.shared.trackMetadata[videoId] {
                // Fallback: track was auto-synced, not in any synced playlist
                // Find which playlist it belongs to (if any)
                let pid = trackPlaylistMap[videoId]?.playlistId ?? "library"
                let ptitle = trackPlaylistMap[videoId]?.playlistTitle ?? "Downloads"
                item = PendingSyncItem(
                    videoId: videoId, title: meta.title, artist: meta.artist,
                    album: meta.album, durationSeconds: meta.durationSeconds,
                    thumbnailURL: meta.thumbnailURL,
                    playlistId: pid, playlistTitle: ptitle
                )
            } else {
                // No metadata at all — skip (can't construct proper Track)
                print("[Sync] Verify: no metadata for \(videoId), skipping re-sync")
                continue
            }

            pendingSyncQueue.append(item)
            alreadyQueued.insert(videoId)
            resynced += 1
        }
        savePendingQueue()

        let result = VerifyResult(
            phoneThinksSynced: phoneThinksSynced,
            actuallyOnWatch: watchSet.count,
            missingOnWatch: falseSynced.count,
            resynced: resynced,
            date: Date()
        )
        lastVerifyResult = result
        isVerifying = false

        print("[Sync] Verify: phone=\(phoneThinksSynced) watch=\(watchSet.count) missing=\(falseSynced.count) resyncing=\(resynced)")

        // Push updated playlist indexes so Watch has correct metadata
        pushAllPlaylistIndexes()

        // Start re-syncing missing tracks
        if resynced > 0 {
            drainPendingQueue()
        }
    }

    // MARK: - Private

    private func drainPendingQueue() {
        guard isAvailable else { return }

        // Clean already-synced items from queue (single source of truth)
        let beforeCount = pendingSyncQueue.count
        pendingSyncQueue.removeAll { syncedTrackIds.contains($0.videoId) }
        if pendingSyncQueue.count != beforeCount { savePendingQueue() }

        // Build transfer list — items STAY in queue until confirmed synced
        var toSync: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []

        for (i, item) in pendingSyncQueue.enumerated() {
            guard !transferringTrackIds.contains(item.videoId) else { continue }
            guard let localURL = AudioDownloader.shared.localURL(for: item.videoId) else { continue }
            let track = Track(
                id: item.videoId, videoId: item.videoId, title: item.title,
                artist: item.artist, album: item.album,
                durationSeconds: item.durationSeconds, thumbnailURL: item.thumbnailURL
            )
            toSync.append((track, localURL, item.playlistId, item.playlistTitle, i))
        }

        guard !toSync.isEmpty else { return }

        for item in toSync {
            transferringTrackIds.insert(item.track.videoId)
        }
        hadActiveSyncs = true

        // Split: WiFi-failed tracks always go Bluetooth; rest try WiFi if Watch reachable
        let watchReachable = session?.isReachable == true
        if watchReachable {
            var wifiItems: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []
            var btItems: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []
            for item in toSync {
                if wifiFailedVideoIds.contains(item.track.videoId) {
                    btItems.append(item)
                } else {
                    wifiItems.append(item)
                }
            }
            if !wifiItems.isEmpty { syncViaDirectDownload(wifiItems) }
            if !btItems.isEmpty { syncViaTransferFile(btItems) }
        } else {
            syncViaTransferFile(toSync)
        }
    }

    /// Fast path: resolve stream URLs and tell Watch to download directly over WiFi.
    /// Falls back to transferFile for any track that fails URL resolution or sendMessage.
    /// Each sent track gets a 120s timeout — if Watch doesn't respond, falls back to Bluetooth.
    private func syncViaDirectDownload(_ items: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)]) {
        guard let session else {
            syncViaTransferFile(items)
            return
        }

        Task {
            var fallback: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []

            // Resolve URLs with bounded concurrency (avoid rate limiting)
            await withTaskGroup(of: (Int, URL?).self) { group in
                var pending = items.enumerated().makeIterator()

                // Launch first batch (max 3 concurrent)
                for _ in 0..<3 {
                    guard let (idx, item) = pending.next() else { break }
                    group.addTask {
                        let url = try? await YTMusicClient.shared.fetchAudioStreamURL(videoId: item.track.videoId)
                        return (idx, url)
                    }
                }

                for await (idx, streamURL) in group {
                    let item = items[idx]
                    if let streamURL {
                        let request = AudioDownloader.buildStreamRequest(streamURL: streamURL)
                        var headers: [String: String] = [:]
                        for (key, value) in request.allHTTPHeaderFields ?? [:] {
                            headers[key] = value
                        }

                        let payload = DirectDownloadPayload(
                            track: item.track,
                            playlistId: item.playlistId,
                            playlistTitle: item.playlistTitle,
                            indexInPlaylist: item.index,
                            streamURL: streamURL.absoluteString,
                            headers: headers,
                            thumbnailDownloadURL: item.track.thumbnailURL
                        )

                        if let data = try? JSONEncoder().encode(payload) {
                            let msg: [String: Any] = [
                                WatchMessageKey.type.rawValue: WatchMessageType.directDownload.rawValue,
                                WatchMessageKey.payload.rawValue: data.base64EncodedString()
                            ]
                            let videoId = item.track.videoId
                            session.sendMessage(msg, replyHandler: nil) { [weak self] error in
                                // sendMessage failed → mark WiFi-failed, remove from transferring, re-drain picks up via Bluetooth
                                print("[Sync] sendMessage failed for \(videoId): \(error.localizedDescription)")
                                Task { @MainActor in
                                    guard let self else { return }
                                    self.cancelWifiTimeout(for: videoId)
                                    self.wifiFailedVideoIds.insert(videoId)
                                    self.transferringTrackIds.remove(videoId)
                                    self.drainPendingQueue()
                                }
                            }
                            // Start timeout — if Watch doesn't respond in 120s, fall back to Bluetooth
                            startWifiTimeout(for: videoId)
                            print("[Sync] → WiFi download \(item.track.title)")
                        } else {
                            fallback.append(item)
                        }
                    } else {
                        // URL resolution failed — fall back to Bluetooth transfer
                        fallback.append(item)
                    }

                    // Launch next item
                    if let (nextIdx, nextItem) = pending.next() {
                        group.addTask {
                            let url = try? await YTMusicClient.shared.fetchAudioStreamURL(videoId: nextItem.track.videoId)
                            return (nextIdx, url)
                        }
                    }
                }
            }

            // Transfer any URL-resolution failures via Bluetooth
            if !fallback.isEmpty {
                print("[Sync] Falling back to Bluetooth for \(fallback.count) tracks")
                syncViaTransferFile(fallback)
            }
        }
    }

    // MARK: - WiFi Download Timeout

    private func startWifiTimeout(for videoId: String) {
        wifiTimeoutTasks[videoId]?.cancel()
        wifiTimeoutTasks[videoId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Still waiting? → fall back to Bluetooth
            guard self.transferringTrackIds.contains(videoId),
                  !self.syncedTrackIds.contains(videoId) else { return }
            print("[Sync] WiFi download timeout: \(videoId) — falling back to Bluetooth")
            self.wifiFailedVideoIds.insert(videoId)
            self.transferringTrackIds.remove(videoId)
            self.drainPendingQueue()
        }
    }

    private func cancelWifiTimeout(for videoId: String) {
        wifiTimeoutTasks[videoId]?.cancel()
        wifiTimeoutTasks.removeValue(forKey: videoId)
    }

    private func cancelAllWifiTimeouts() {
        for (_, task) in wifiTimeoutTasks { task.cancel() }
        wifiTimeoutTasks.removeAll()
    }

    /// Slow path: transfer files over Bluetooth via WCSession.transferFile
    private func syncViaTransferFile(_ items: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)]) {
        Task.detached {
            // Download thumbnails first
            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask {
                        if let thumbStr = item.track.thumbnailURL, let thumbURL = URL(string: thumbStr) {
                            await Self.downloadThumbnailBackground(from: thumbURL, videoId: item.track.videoId)
                        }
                    }
                }
            }
            await MainActor.run { [items] in
                guard let session = self.session else { return }
                for item in items {
                    let meta = TrackTransferMetadata(track: item.track, playlistId: item.playlistId, playlistTitle: item.playlistTitle, indexInPlaylist: item.index)
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
        // Track synced playlists locally
        if let idx = syncedPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            syncedPlaylists[idx] = playlist
        } else {
            syncedPlaylists.append(playlist)
        }
        saveSyncState()
        pushAllPlaylistIndexes()
    }

    private func pushAllPlaylistIndexes() {
        guard let session, session.activationState == .activated else { return }
        // Send ALL playlist indexes in one applicationContext (single slot — must batch)
        guard let data = try? JSONEncoder().encode(syncedPlaylists) else { return }
        let context: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.playlistIndex.rawValue,
            WatchMessageKey.payload.rawValue: data.base64EncodedString()
        ]
        try? session.updateApplicationContext(context)
    }

    /// Handle result of Watch direct WiFi download attempt.
    private func handleDirectDownloadResult(videoId: String, success: Bool) {
        cancelWifiTimeout(for: videoId)

        if success {
            transferringTrackIds.remove(videoId)
            syncedTrackIds.insert(videoId)
            pendingSyncQueue.removeAll { $0.videoId == videoId }
            savePendingQueue()
            saveSyncState()
            print("[Sync] ✓ WiFi download \(videoId)")
            checkSyncCompletion()
        } else {
            // Mark WiFi-failed so drain uses Bluetooth, remove from transferring, re-drain
            print("[Sync] ✗ WiFi download failed \(videoId) — will retry via Bluetooth")
            wifiFailedVideoIds.insert(videoId)
            transferringTrackIds.remove(videoId)
            // Item is still in pendingSyncQueue → drainPendingQueue will pick it up via Bluetooth
            drainPendingQueue()
        }
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
            // Push all playlist indexes so Watch has full state
            self.pushAllPlaylistIndexes()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isWatchReachable = reachable
            if reachable {
                // Fresh connection — clear WiFi-failed so tracks can try WiFi again
                self.wifiFailedVideoIds.removeAll()
                self.drainPendingQueue()
            } else {
                // Watch went unreachable — cancel pending WiFi timeouts
                // (items stay in queue, will transfer via Bluetooth on reconnect)
                self.cancelAllWifiTimeouts()
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

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let typeStr = message[WatchMessageKey.type.rawValue] as? String
        let trackIds = message["trackIds"] as? [String]
        let videoId = message["videoId"] as? String
        let success = message["success"] as? Bool
        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }
            switch type {
            case .syncInventory:
                self.handleSyncInventory(watchTrackIds: trackIds ?? [])
            case .downloadResult:
                if let videoId { self.handleDirectDownloadResult(videoId: videoId, success: success ?? false) }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let typeStr = userInfo[WatchMessageKey.type.rawValue] as? String
        let videoId = userInfo["videoId"] as? String
        let success = userInfo["success"] as? Bool
        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }
            if type == .downloadResult, let videoId {
                self.handleDirectDownloadResult(videoId: videoId, success: success ?? false)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
