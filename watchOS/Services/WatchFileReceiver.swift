import Foundation
import WatchConnectivity

// Receives audio files and playlist metadata from the iPhone companion app.
@MainActor
final class WatchFileReceiver: NSObject, ObservableObject {

    static let shared = WatchFileReceiver()

    @Published var playlists: [Playlist] = []
    @Published var receivingCount = 0
    @Published var syncingPlaylistName: String? = nil
    @Published var syncedTrackCount = 0
    @Published var syncTotalCount = 0
    /// Cached available playlists — only tracks with files on disk. Call `refreshAvailable()` to update.
    @Published private(set) var cachedAvailablePlaylists: [Playlist] = []
    private var _cachedTrackIds: Set<String>?

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
        refreshAvailable()
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
        _cachedTrackIds = nil
        refreshAvailable()
    }

    func isAvailable(_ videoId: String) -> Bool {
        audioURL(for: videoId) != nil
    }

    func rescanFiles() {
        loadPlaylistsFromDisk()

        // Discover audio files on disk not in any playlist
        let knownIds = Set(playlists.flatMap { $0.tracks.map(\.videoId) })
        let onDisk = availableTrackIds()
        let orphaned = onDisk.subtracting(knownIds)

        if !orphaned.isEmpty {
            // Add orphaned tracks to an "Unsorted" playlist
            let unsortedId = "__unsorted__"
            var unsorted = playlists.first(where: { $0.id == unsortedId }) ?? Playlist(
                id: unsortedId, title: "Unsorted", thumbnailURL: nil, tracks: []
            )
            for videoId in orphaned {
                if !unsorted.tracks.contains(where: { $0.videoId == videoId }) {
                    let track = Track(id: videoId, videoId: videoId, title: videoId, artist: "Unknown", durationSeconds: 0)
                    unsorted.tracks.append(track)
                }
            }
            upsertPlaylist(unsorted)
            print("[Receiver] Found \(orphaned.count) orphaned audio files, added to Unsorted")
        }

        refreshAvailable()
    }

    func availableTrackIds() -> Set<String> {
        guard let files = try? fm.contentsOfDirectory(at: Self.audioDirectory, includingPropertiesForKeys: nil) else { return [] }
        return Set(files.filter { $0.pathExtension == "m4a" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    // Filter playlists to only tracks actually on device
    var availablePlaylists: [Playlist] {
        cachedAvailablePlaylists
    }

    func refreshAvailable() {
        let ids = availableTrackIds()
        _cachedTrackIds = ids
        cachedAvailablePlaylists = playlists.compactMap { playlist -> Playlist? in
            var p = playlist
            p.tracks = playlist.tracks.filter { ids.contains($0.videoId) }
            return p.tracks.isEmpty ? nil : p
        }
    }

    /// Cached available track IDs — avoids disk scan per call
    func cachedOrFreshTrackIds() -> Set<String> {
        if let cached = _cachedTrackIds { return cached }
        let ids = availableTrackIds()
        _cachedTrackIds = ids
        return ids
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

    func storageMB(for playlist: Playlist) -> Double {
        var total: Int64 = 0
        for track in playlist.tracks {
            let url = Self.audioDirectory.appendingPathComponent("\(track.videoId).m4a")
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            total += Int64(size)
        }
        return Double(total) / 1_000_000
    }

    var totalDeviceStorageMB: Double {
        let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? Int64) ?? 0
        return Double(total) / 1_000_000
    }

    var freeDeviceStorageMB: Double {
        let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? Int64) ?? 0
        return Double(free) / 1_000_000
    }

    // MARK: - Direct WiFi Download

    /// Max concurrent direct downloads on Watch
    private static let maxWatchDownloads = 3
    @Published var directDownloadCount = 0
    private var directDownloadQueue: [DirectDownloadPayload] = []

    private func handleDirectDownload(_ payload: DirectDownloadPayload) {
        let videoId = payload.track.videoId

        // Skip if already have this track
        guard audioURL(for: videoId) == nil else {
            sendDownloadResult(videoId: videoId, success: true)
            upsertTrackIntoPlaylist(payload)
            return
        }

        // Queue if at capacity
        if directDownloadCount >= Self.maxWatchDownloads {
            if !directDownloadQueue.contains(where: { $0.track.videoId == videoId }) {
                directDownloadQueue.append(payload)
                print("[Receiver] Queued WiFi download (\(directDownloadQueue.count) waiting): \(payload.track.title)")
            }
            return
        }

        startDirectDownload(payload)
    }

    private func startDirectDownload(_ payload: DirectDownloadPayload) {
        let videoId = payload.track.videoId
        receivingCount += 1
        directDownloadCount += 1
        syncingPlaylistName = payload.playlistTitle
        syncTotalCount += 1

        Task {
            do {
                guard let streamURL = URL(string: payload.streamURL) else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: streamURL)
                for (key, value) in payload.headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                request.timeoutInterval = 120

                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status), !data.isEmpty else {
                    throw URLError(.badServerResponse)
                }

                let destURL = Self.audioDirectory.appendingPathComponent("\(videoId).m4a")
                try? fm.removeItem(at: destURL)
                try data.write(to: destURL)

                // Download thumbnail
                if let thumbURLStr = payload.thumbnailDownloadURL,
                   let thumbURL = URL(string: thumbURLStr) {
                    if let (thumbData, _) = try? await URLSession.shared.data(from: thumbURL),
                       !thumbData.isEmpty {
                        let thumbDest = Self.thumbnailDirectory.appendingPathComponent("\(videoId).jpg")
                        try? fm.removeItem(at: thumbDest)
                        try? thumbData.write(to: thumbDest)
                    }
                }

                upsertTrackIntoPlaylist(payload)
                syncedTrackCount += 1

                print("[Receiver] WiFi download ✓ \(payload.track.title) (\(syncedTrackCount)/\(syncTotalCount))")
                sendDownloadResult(videoId: videoId, success: true)

            } catch {
                print("[Receiver] WiFi download ✘ \(videoId): \(error.localizedDescription)")
                sendDownloadResult(videoId: videoId, success: false)
            }

            _cachedTrackIds = nil
            refreshAvailable()

            // Decrement and process next queued download
            self.receivingCount = max(0, self.receivingCount - 1)
            self.directDownloadCount = max(0, self.directDownloadCount - 1)
            self.processNextDirectDownload()

            if self.receivingCount == 0 {
                // Clear sync progress after a delay
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.receivingCount == 0 {
                    self.syncingPlaylistName = nil
                    self.syncedTrackCount = 0
                    self.syncTotalCount = 0
                }
            }
        }
    }

    private func processNextDirectDownload() {
        while directDownloadCount < Self.maxWatchDownloads && !directDownloadQueue.isEmpty {
            let next = directDownloadQueue.removeFirst()
            // Skip if already downloaded while queued
            if audioURL(for: next.track.videoId) != nil {
                sendDownloadResult(videoId: next.track.videoId, success: true)
                upsertTrackIntoPlaylist(next)
                continue
            }
            startDirectDownload(next)
            break
        }
    }

    private func upsertTrackIntoPlaylist(_ payload: DirectDownloadPayload) {
        if var playlist = playlists.first(where: { $0.id == payload.playlistId }) {
            if !playlist.tracks.contains(where: { $0.videoId == payload.track.videoId }) {
                let idx = payload.indexInPlaylist
                if idx >= 0 && idx <= playlist.tracks.count {
                    playlist.tracks.insert(payload.track, at: min(idx, playlist.tracks.count))
                } else {
                    playlist.tracks.append(payload.track)
                }
            }
            upsertPlaylist(playlist)
        } else {
            let newPlaylist = Playlist(
                id: payload.playlistId,
                title: payload.playlistTitle,
                thumbnailURL: nil,
                tracks: [payload.track]
            )
            upsertPlaylist(newPlaylist)
        }
    }

    private func sendDownloadResult(videoId: String, success: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let msg: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.downloadResult.rawValue,
            "videoId": videoId,
            "success": success
        ]
        // Use transferUserInfo for reliability (sendMessage may fail if phone app not foreground)
        WCSession.default.transferUserInfo(msg)
    }

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
        _cachedTrackIds = nil // invalidate
        refreshAvailable()
    }

    /// Batch upsert — saves disk once, refreshes once. Use when receiving many playlists at once.
    private func upsertPlaylistsBatch(_ incoming: [Playlist]) {
        var existingById = Dictionary(uniqueKeysWithValues: playlists.enumerated().map { ($0.element.id, $0.offset) })
        for p in incoming {
            if let idx = existingById[p.id] {
                playlists[idx] = p
            } else {
                existingById[p.id] = playlists.count
                playlists.append(p)
            }
        }
        savePlaylistsToDisk()
        _cachedTrackIds = nil
        refreshAvailable()
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
        _cachedTrackIds = nil
        refreshAvailable()
    }

    func cleanupOrphanedFiles() {
        // Don't cleanup while actively receiving files — race condition
        guard receivingCount == 0 else {
            print("[Receiver] Skipping cleanup — \(receivingCount) files being received")
            return
        }
        let allTrackIds = Set(playlists.flatMap { $0.tracks.map(\.videoId) })
        let onDisk = availableTrackIds()
        let orphans = onDisk.subtracting(allTrackIds)
        guard !orphans.isEmpty else { return }
        // Delay cleanup to give pending transfers time to register
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Re-check after delay — new playlists may have been upserted
            let currentTrackIds = Set(self.playlists.flatMap { $0.tracks.map(\.videoId) })
            let stillOrphaned = orphans.subtracting(currentTrackIds)
            guard self.receivingCount == 0 else { return }
            for id in stillOrphaned {
                let audioFile = Self.audioDirectory.appendingPathComponent("\(id).m4a")
                let thumbFile = Self.thumbnailDirectory.appendingPathComponent("\(id).jpg")
                try? self.fm.removeItem(at: audioFile)
                try? self.fm.removeItem(at: thumbFile)
            }
            if !stillOrphaned.isEmpty {
                print("[Receiver] Cleaned up \(stillOrphaned.count) orphaned files")
            }
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
            defer {
                self.receivingCount = max(0, self.receivingCount - 1)
                if self.receivingCount == 0 {
                    // Reset sync progress when all transfers done
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if self.receivingCount == 0 {
                            self.syncingPlaylistName = nil
                            self.syncedTrackCount = 0
                            self.syncTotalCount = 0
                        }
                    }
                }
            }

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
            // Track whether write succeeded — only confirm sync to phone if file actually landed
            let wroteSuccessfully: Bool
            do {
                try self.fm.copyItem(at: fileURL, to: destURL)
                // Verify file is non-empty
                let size = (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                wroteSuccessfully = size > 100_000
            } catch {
                print("[Receiver] BT write failed for \(transfer.track.videoId): \(error.localizedDescription)")
                wroteSuccessfully = false
            }

            // Confirm to phone whether file actually wrote (closes the BT-sync drift bug)
            self.sendDownloadResult(videoId: transfer.track.videoId, success: wroteSuccessfully)

            guard wroteSuccessfully else { return }

            // Update sync progress
            self.syncingPlaylistName = transfer.playlistTitle
            self.syncedTrackCount += 1

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

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncomingMessage(message, replyHandler: nil)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // Handle syncVerify SYNCHRONOUSLY — replyHandler must be called promptly,
        // dispatching to Task { @MainActor } risks calling it after WCSession invalidates it.
        if let typeStr = message[WatchMessageKey.type.rawValue] as? String,
           typeStr == WatchMessageType.syncVerify.rawValue {
            // Inline directory scan (no MainActor needed — just FileManager).
            // Only count files larger than 100KB — excludes in-flight transfers and corrupt files.
            let audioDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Audio", isDirectory: true)
            let ids: [String]
            if let files = try? FileManager.default.contentsOfDirectory(
                at: audioDir, includingPropertiesForKeys: [.fileSizeKey]
            ) {
                ids = files.compactMap { url -> String? in
                    guard url.pathExtension == "m4a" else { return nil }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return size > 100_000 ? url.deletingPathExtension().lastPathComponent : nil
                }
            } else {
                ids = []
            }
            replyHandler([
                WatchMessageKey.type.rawValue: WatchMessageType.syncInventory.rawValue,
                "trackIds": ids
            ])
            return
        }

        // Everything else can go through async handling
        nonisolated(unsafe) let unsafeReply = replyHandler
        let sendableReply: @Sendable ([String: Any]) -> Void = { dict in unsafeReply(dict) }
        handleIncomingMessage(message, replyHandler: sendableReply)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncomingMessage(userInfo)
    }

    private nonisolated func handleIncomingMessage(_ msg: [String: Any], replyHandler: (@Sendable ([String: Any]) -> Void)? = nil) {
        // Extract all values from msg before crossing isolation boundary
        let typeStr = msg[WatchMessageKey.type.rawValue] as? String
        let videoId = msg["videoId"] as? String
        let payloadB64 = msg[WatchMessageKey.payload.rawValue] as? String
        _ = replyHandler // syncVerify handled synchronously in delegate; other cases don't need reply
        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }
            switch type {
            case .deleteTrack:
                if let videoId { self.deleteTrack(videoId: videoId) }
            case .directDownload:
                // Phone sent us a stream URL — download directly over WiFi
                if let b64 = payloadB64,
                   let data = Data(base64Encoded: b64),
                   let payload = try? JSONDecoder().decode(DirectDownloadPayload.self, from: data) {
                    self.handleDirectDownload(payload)
                }
            default:
                break
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
                guard let b64, let data = Data(base64Encoded: b64) else { return }
                // Try batch format (array of playlists) first, fall back to single
                if let batchPlaylists = try? JSONDecoder().decode([Playlist].self, from: data) {
                    // Batch upsert: mutate array, save disk ONCE at end (not per playlist).
                    // 30 playlists used to trigger 30 disk writes + 30 directory scans → Watch crash.
                    self.upsertPlaylistsBatch(batchPlaylists)
                    print("[Receiver] Updated \(batchPlaylists.count) playlists from applicationContext")
                } else if let playlist = try? JSONDecoder().decode(Playlist.self, from: data) {
                    self.upsertPlaylist(playlist)
                }
                self.cleanupOrphanedFiles()
            case .deleteTrack:
                if let videoId { self.deleteTrack(videoId: videoId) }
            default:
                break
            }
        }
    }
}
