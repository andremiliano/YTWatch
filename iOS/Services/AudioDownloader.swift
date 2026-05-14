import Foundation
import UIKit

// Thread-safe storage for background session completion handler — must be outside @MainActor
private final class BGHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    func get() -> (() -> Void)? { lock.withLock { handler } }
    func set(_ h: (() -> Void)?) { lock.withLock { handler = h } }
}
private let _bgHandlerBox = BGHandlerBox()

@MainActor
final class AudioDownloader: NSObject, ObservableObject {

    static let shared = AudioDownloader()

    // MARK: - Published State

    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadedTracks: [String: URL] = [:]
    @Published var downloadErrors: [String: String] = [:]
    @Published var activeDownloadCount = 0
    @Published var totalQueuedCount = 0
    @Published var completedInBatch = 0
    @Published var estimatedSecondsRemaining: Double?

    private(set) var trackMetadata: [String: TrackMeta] = [:]

    struct TrackMeta: Codable {
        let title: String
        let artist: String
        let thumbnailURL: String?
        let durationSeconds: Int
        let album: String?

        // Backward compat: old data may not have these fields
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            artist = try c.decode(String.self, forKey: .artist)
            thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
            durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
            album = try c.decodeIfPresent(String.self, forKey: .album)
        }

        init(title: String, artist: String, thumbnailURL: String?, durationSeconds: Int = 0, album: String? = nil) {
            self.title = title
            self.artist = artist
            self.thumbnailURL = thumbnailURL
            self.durationSeconds = durationSeconds
            self.album = album
        }
    }

    // MARK: - Internal State

    /// Tracks currently in any download phase (resolving URL, downloading, or awaiting bg delegate)
    private var downloadingVideoIds: Set<String> = []
    /// Tracks sitting in the global queue waiting to start
    private var queuedVideoIds: Set<String> = []

    // Maps videoId → Swift concurrency Task (for stream URL resolution in single-track download)
    private var resolveTasks: [String: Task<URL, Error>] = [:]
    // Maps URLSessionDownloadTask.taskIdentifier → videoId
    private var taskToVideoId: [Int: String] = [:]
    // Reverse: videoId → taskIdentifier (for O(1) lookups)
    private var videoIdToTaskId: [String: Int] = [:]
    // Continuations for callers awaiting download completion (single-track download() calls)
    private var completionContinuations: [String: [CheckedContinuation<URL, Error>]] = [:]

    /// Global download queue — all batches feed into this. Prevents unbounded concurrent resolves.
    private var globalQueue: [QueuedDownload] = []
    private var globalQueueRunning = false
    /// Max concurrent URL resolutions (not downloads — bg session manages download concurrency)
    nonisolated private static let maxConcurrentResolves = 3

    struct QueuedDownload {
        let track: Track
        let playlistId: String
        let playlistTitle: String
    }

    private var bgSession: URLSession!
    private var foregroundSession: URLSession!
    private var batchStartTime: Date?
    private var batchStartCompleted = 0
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    // Persisted pending downloads for background resume
    struct PendingDownload: Codable {
        let videoId: String
        let playlistId: String?
        let playlistTitle: String?
    }
    private var pendingDownloads: [String: PendingDownload] = [:]

    static let backgroundSessionId = "com.ytwatch.bgdownload"

    nonisolated static var backgroundSessionCompletionHandler: (() -> Void)? {
        get { _bgHandlerBox.get() }
        set { _bgHandlerBox.set(newValue) }
    }

    nonisolated static var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    override init() {
        super.init()

        // Background session — iOS manages downloads even when app is suspended
        let bgConfig = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionId)
        bgConfig.isDiscretionary = false
        bgConfig.sessionSendsLaunchEvents = true
        bgConfig.timeoutIntervalForResource = 600
        bgConfig.timeoutIntervalForRequest = 120
        bgConfig.httpMaximumConnectionsPerHost = 2
        bgSession = URLSession(configuration: bgConfig, delegate: self, delegateQueue: nil)

        // Foreground session for stream URL resolution (fast API calls)
        let fgConfig = URLSessionConfiguration.default
        fgConfig.timeoutIntervalForResource = 60
        fgConfig.timeoutIntervalForRequest = 30
        foregroundSession = URLSession(configuration: fgConfig)

        createDownloadsDirectory()
        loadTrackMetadata()
        loadPendingDownloads()
        scanExistingDownloads()
        reconcileBackgroundTasks()
    }

    // MARK: - Public Queries

    func isDownloaded(_ videoId: String) -> Bool { downloadedTracks[videoId] != nil }
    func isDownloading(_ videoId: String) -> Bool { downloadingVideoIds.contains(videoId) }
    func isQueued(_ videoId: String) -> Bool { queuedVideoIds.contains(videoId) }
    /// Track is in any active state: queued, resolving, or downloading
    func isActive(_ videoId: String) -> Bool { isDownloading(videoId) || isQueued(videoId) }
    var hasActiveDownloads: Bool { !downloadingVideoIds.isEmpty }
    func localURL(for videoId: String) -> URL? { downloadedTracks[videoId] }

    // MARK: - Single-Track Download (awaits completion)

    /// Downloads a single track and returns the local file URL when complete.
    /// For batch downloads, use `downloadBatch()` instead.
    func download(track: Track, playlistId: String? = nil, playlistTitle: String? = nil) async throws -> URL {
        if let existing = downloadedTracks[track.videoId] { return existing }

        // If already in progress, wait for it
        if downloadingVideoIds.contains(track.videoId) {
            return try await withCheckedThrowingContinuation { cont in
                completionContinuations[track.videoId, default: []].append(cont)
            }
        }

        downloadErrors.removeValue(forKey: track.videoId)
        downloadingVideoIds.insert(track.videoId)

        trackMetadata[track.videoId] = TrackMeta(
            title: track.title, artist: track.artist, thumbnailURL: track.thumbnailURL,
            durationSeconds: track.durationSeconds, album: track.album
        )
        saveTrackMetadata()

        pendingDownloads[track.videoId] = PendingDownload(videoId: track.videoId, playlistId: playlistId, playlistTitle: playlistTitle)
        savePendingDownloads()

        activeDownloadCount += 1
        downloadProgress[track.videoId] = 0.02

        do {
            // Resolve stream URL
            let streamURL = try await resolveStreamURL(videoId: track.videoId)
            downloadProgress[track.videoId] = 0.1

            // Start background download
            startBackgroundDownload(videoId: track.videoId, streamURL: streamURL)

            // Wait for bg delegate to deliver the file
            return try await withCheckedThrowingContinuation { cont in
                completionContinuations[track.videoId, default: []].append(cont)
            }
        } catch {
            downloadingVideoIds.remove(track.videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            pendingDownloads.removeValue(forKey: track.videoId)
            savePendingDownloads()
            downloadErrors[track.videoId] = error.localizedDescription
            downloadProgress.removeValue(forKey: track.videoId)
            trackCompletion()
            print("[DL] ✘ \(track.title) (\(track.videoId)): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Batch Download (fire-and-forget, pipelined)

    /// Batch download tracks — survives view lifecycle.
    /// All batches feed into a single global queue with bounded URL resolution concurrency.
    /// Background URLSession handles download concurrency independently.
    /// Safe to call multiple times — duplicates are filtered, errors are cleared for retry.
    func downloadBatch(tracks: [Track], playlistId: String, playlistTitle: String) {
        // Clear errors so failed tracks can be retried
        for track in tracks {
            downloadErrors.removeValue(forKey: track.videoId)
        }

        let pending = tracks.filter { t in
            !isDownloaded(t.videoId) && !isDownloading(t.videoId) && !isQueued(t.videoId)
        }
        guard !pending.isEmpty else { return }

        beginBatch(total: pending.count)
        for track in pending {
            queuedVideoIds.insert(track.videoId)
            globalQueue.append(QueuedDownload(track: track, playlistId: playlistId, playlistTitle: playlistTitle))
        }
        drainGlobalQueue()
    }

    /// Processes the global download queue.
    /// Resolves URLs with bounded concurrency, then lets background URLSession handle downloads.
    /// Each task in the group only lasts ~2-5 seconds (URL resolution), NOT minutes (full download).
    private func drainGlobalQueue() {
        guard !globalQueueRunning else { return }
        globalQueueRunning = true

        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                var launched = 0
                while true {
                    let next: QueuedDownload? = await MainActor.run {
                        guard !self.globalQueue.isEmpty else { return nil }
                        return self.globalQueue.removeFirst()
                    }
                    guard let item = next else { break }

                    // Throttle: wait for a resolve slot (not a download slot)
                    if launched >= Self.maxConcurrentResolves {
                        _ = await group.next()
                    }
                    launched += 1

                    group.addTask {
                        do {
                            try await AudioDownloader.shared.resolveAndStartBatchItem(item)
                        } catch {
                            await MainActor.run {
                                let dl = AudioDownloader.shared
                                dl.handleBatchItemFailure(videoId: item.track.videoId, error: error)
                            }
                        }
                    }
                }
                await group.waitForAll()
            }
            await MainActor.run {
                self.globalQueueRunning = false
                if !self.globalQueue.isEmpty {
                    self.drainGlobalQueue()
                }
                // Don't endBatch here — bg downloads are still in progress.
                // endBatch is triggered from handleDownloadCompletion when last download finishes.
            }
        }
    }

    /// Resolves URL and starts background download for a batch item.
    /// Returns after starting the download — does NOT wait for download to complete.
    private func resolveAndStartBatchItem(_ item: QueuedDownload) async throws {
        let track = item.track
        let videoId = track.videoId

        // Move from queued → downloading
        queuedVideoIds.remove(videoId)

        guard !isDownloaded(videoId) else {
            trackCompletion()
            return
        }
        guard Self.isValidVideoId(videoId) else {
            throw DownloadError.badResponse(-1)
        }

        // Check if file already exists on disk
        let destURL = Self.downloadsDirectory.appendingPathComponent("\(videoId).m4a")
        if FileManager.default.fileExists(atPath: destURL.path) {
            downloadedTracks[videoId] = destURL
            downloadProgress[videoId] = 1.0
            trackCompletion()
            checkBatchCompletion()
            return
        }

        downloadingVideoIds.insert(videoId)
        activeDownloadCount += 1

        trackMetadata[videoId] = TrackMeta(
            title: track.title, artist: track.artist, thumbnailURL: track.thumbnailURL,
            durationSeconds: track.durationSeconds, album: track.album
        )
        saveTrackMetadata()

        pendingDownloads[videoId] = PendingDownload(videoId: videoId, playlistId: item.playlistId, playlistTitle: item.playlistTitle)
        savePendingDownloads()

        downloadProgress[videoId] = 0.02

        // Phase 1: Resolve stream URL (~2-5 seconds — this is what we throttle)
        let streamURL = try await resolveStreamURL(videoId: videoId)
        downloadProgress[videoId] = 0.1

        // Phase 2: Start background download — returns immediately
        startBackgroundDownload(videoId: videoId, streamURL: streamURL)
        // Background URLSession delegate handles the rest asynchronously
    }

    private func handleBatchItemFailure(videoId: String, error: Error) {
        queuedVideoIds.remove(videoId)
        downloadingVideoIds.remove(videoId)
        downloadErrors[videoId] = error.localizedDescription
        downloadProgress.removeValue(forKey: videoId)
        activeDownloadCount = max(0, activeDownloadCount - 1)
        trackCompletion()
        print("[DL] ✘ batch \(videoId): \(error.localizedDescription)")
        checkBatchCompletion()
    }

    // MARK: - Stream Resolution & Background Download

    private func resolveStreamURL(videoId: String) async throws -> URL {
        try await YTMusicClient.shared.fetchAudioStreamURL(videoId: videoId)
    }

    private func startBackgroundDownload(videoId: String, streamURL: URL) {
        let request = Self.buildStreamRequest(streamURL: streamURL)
        print("[DL] BG download \(streamURL.host ?? "") for \(videoId)")

        let downloadTask = bgSession.downloadTask(with: request)
        downloadTask.taskDescription = videoId
        taskToVideoId[downloadTask.taskIdentifier] = videoId
        videoIdToTaskId[videoId] = downloadTask.taskIdentifier
        downloadTask.resume()
    }

    static func buildStreamRequest(streamURL: URL) -> URLRequest {
        let comps = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        let clientParam = comps?.queryItems?.first(where: { $0.name == "c" })?.value ?? ""
        let isVR = clientParam == "ANDROID_VR"
        var req = URLRequest(url: streamURL)
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        if isVR {
            req.setValue("com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip", forHTTPHeaderField: "User-Agent")
        } else {
            req.setValue("Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
        }
        if let cookieHeader = YTMusicClient.shared.cookieHeaderForYouTube() {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return req
    }

    // MARK: - Download Completion (called by URLSession delegate)

    private func handleDownloadCompletion(videoId: String, tempURL: URL?, error: Error?) {
        let pendingInfo = pendingDownloads[videoId]
        pendingDownloads.removeValue(forKey: videoId)
        savePendingDownloads()

        if let error {
            let msg = error.localizedDescription
            downloadErrors[videoId] = msg
            downloadProgress.removeValue(forKey: videoId)
            downloadingVideoIds.remove(videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            trackCompletion()
            print("[DL] ✘ \(videoId): \(msg)")
            if let conts = completionContinuations.removeValue(forKey: videoId) {
                for cont in conts { cont.resume(throwing: error) }
            }
            checkBatchCompletion()
            return
        }

        guard let tempURL else {
            let err = DownloadError.badResponse(-1)
            downloadErrors[videoId] = err.localizedDescription
            downloadProgress.removeValue(forKey: videoId)
            downloadingVideoIds.remove(videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            trackCompletion()
            if let conts = completionContinuations.removeValue(forKey: videoId) {
                for cont in conts { cont.resume(throwing: err) }
            }
            checkBatchCompletion()
            return
        }

        let destURL = Self.downloadsDirectory.appendingPathComponent("\(videoId).m4a")
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            downloadErrors[videoId] = error.localizedDescription
            downloadProgress.removeValue(forKey: videoId)
            downloadingVideoIds.remove(videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            trackCompletion()
            if let conts = completionContinuations.removeValue(forKey: videoId) {
                for cont in conts { cont.resume(throwing: error) }
            }
            checkBatchCompletion()
            return
        }

        downloadedTracks[videoId] = destURL
        downloadProgress[videoId] = 1.0
        downloadingVideoIds.remove(videoId)
        activeDownloadCount = max(0, activeDownloadCount - 1)
        trackCompletion()
        print("[DL] ✓ \(videoId)")

        // Auto-sync to watch
        if let meta = trackMetadata[videoId] {
            let track = Track(
                id: videoId, videoId: videoId, title: meta.title,
                artist: meta.artist, album: meta.album, durationSeconds: meta.durationSeconds,
                thumbnailURL: meta.thumbnailURL
            )
            if let pid = pendingInfo?.playlistId, let ptitle = pendingInfo?.playlistTitle {
                WatchSyncManager.shared.queueTrackForSync(track, fileURL: destURL, playlistId: pid, playlistTitle: ptitle)
            }
        }

        if let conts = completionContinuations.removeValue(forKey: videoId) {
            for cont in conts { cont.resume(returning: destURL) }
        }

        checkBatchCompletion()
    }

    // MARK: - Cancel / Delete

    func cancelDownload(videoId: String) {
        // Cancel resolve task if in progress
        resolveTasks[videoId]?.cancel()
        resolveTasks.removeValue(forKey: videoId)

        // Cancel any active background download task
        if let taskId = videoIdToTaskId[videoId] {
            bgSession.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == taskId {
                    task.cancel()
                }
            }
            taskToVideoId.removeValue(forKey: taskId)
            videoIdToTaskId.removeValue(forKey: videoId)
        }

        // Remove from queue if not yet started
        globalQueue.removeAll { $0.track.videoId == videoId }
        queuedVideoIds.remove(videoId)

        downloadingVideoIds.remove(videoId)
        downloadProgress.removeValue(forKey: videoId)
        pendingDownloads.removeValue(forKey: videoId)
        savePendingDownloads()
        activeDownloadCount = max(0, activeDownloadCount - 1)

        // Fail any waiting continuations
        if let conts = completionContinuations.removeValue(forKey: videoId) {
            for cont in conts { cont.resume(throwing: CancellationError()) }
        }
        checkBatchCompletion()
    }

    func deleteDownload(videoId: String) {
        if let url = downloadedTracks[videoId] {
            try? FileManager.default.removeItem(at: url)
            downloadedTracks.removeValue(forKey: videoId)
        }
        downloadProgress.removeValue(forKey: videoId)
        downloadErrors.removeValue(forKey: videoId)
        trackMetadata.removeValue(forKey: videoId)
        pendingDownloads.removeValue(forKey: videoId)
        saveTrackMetadata()
        savePendingDownloads()
        WatchSyncManager.shared.removeFromWatch(videoId: videoId)
    }

    func deleteAllDownloads(for videoIds: [String]) {
        for id in videoIds { deleteDownload(videoId: id) }
    }

    func deleteAllDownloads() {
        let allIds = Array(downloadedTracks.keys)
        for id in allIds { deleteDownload(videoId: id) }
    }

    // MARK: - Storage

    var totalDownloadSizeBytes: Int64 {
        var total: Int64 = 0
        for url in downloadedTracks.values {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            total += size
        }
        return total
    }

    var formattedTotalSize: String {
        let bytes = totalDownloadSizeBytes
        if bytes == 0 { return "0 MB" }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        if mb < 1 { return "< 1 MB" }
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Batch Progress

    func beginBatch(total: Int) {
        if totalQueuedCount > 0 {
            // Already in a batch — add to it
            totalQueuedCount += total
        } else {
            totalQueuedCount = total
            completedInBatch = 0
            batchStartTime = Date()
            batchStartCompleted = 0
            estimatedSecondsRemaining = nil
        }
        beginBackgroundTask()
    }

    private func checkBatchCompletion() {
        guard totalQueuedCount > 0 else { return }
        // Batch is done when: no queued items, no downloading items, drain not running
        if queuedVideoIds.isEmpty && downloadingVideoIds.isEmpty && !globalQueueRunning && globalQueue.isEmpty {
            endBatch()
        }
    }

    func endBatch() {
        totalQueuedCount = 0
        completedInBatch = 0
        estimatedSecondsRemaining = nil
        batchStartTime = nil
        endBackgroundTask()
    }

    private func trackCompletion() {
        completedInBatch += 1
        guard let start = batchStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        let done = completedInBatch - batchStartCompleted
        guard done > 0 else { return }
        let perTrack = elapsed / Double(done)
        let remaining = totalQueuedCount - completedInBatch
        estimatedSecondsRemaining = perTrack * Double(max(remaining, 0))
    }

    // MARK: - Background Task (keeps app alive during URL resolution)

    private func beginBackgroundTask() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AudioDownload") {
            Task { @MainActor [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    // MARK: - Reconciliation

    private func reconcileBackgroundTasks() {
        bgSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    if let videoId = task.taskDescription, !videoId.isEmpty {
                        self.taskToVideoId[task.taskIdentifier] = videoId
                        self.videoIdToTaskId[videoId] = task.taskIdentifier
                        self.downloadingVideoIds.insert(videoId)
                        if self.downloadProgress[videoId] == nil {
                            self.downloadProgress[videoId] = 0.1
                        }
                    }
                }
                self.activeDownloadCount = self.downloadingVideoIds.count
            }
        }
    }

    // MARK: - Validation

    private static func isValidVideoId(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{8,16}$", options: .regularExpression) != nil
    }

    // MARK: - Persistence

    private func saveTrackMetadata() {
        if let data = try? JSONEncoder().encode(trackMetadata) {
            UserDefaults.standard.set(data, forKey: "trackMetadata")
        }
    }

    private func loadTrackMetadata() {
        if let data = UserDefaults.standard.data(forKey: "trackMetadata"),
           let meta = try? JSONDecoder().decode([String: TrackMeta].self, from: data) {
            trackMetadata = meta
        }
    }

    private func savePendingDownloads() {
        if let data = try? JSONEncoder().encode(pendingDownloads) {
            UserDefaults.standard.set(data, forKey: "pendingDownloads")
        }
    }

    private func loadPendingDownloads() {
        if let data = UserDefaults.standard.data(forKey: "pendingDownloads"),
           let pending = try? JSONDecoder().decode([String: PendingDownload].self, from: data) {
            pendingDownloads = pending
        }
    }

    private func createDownloadsDirectory() {
        try? FileManager.default.createDirectory(at: Self.downloadsDirectory, withIntermediateDirectories: true)
    }

    private func scanExistingDownloads() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.downloadsDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            if file.pathExtension == "m4a" {
                let videoId = file.deletingPathExtension().lastPathComponent
                downloadedTracks[videoId] = file
                downloadProgress[videoId] = 1.0
                pendingDownloads.removeValue(forKey: videoId)
            } else if file.pathExtension == "tmp" || file.pathExtension == "bgdl" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        savePendingDownloads()
    }
}

// MARK: - URLSessionDownloadDelegate

extension AudioDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let taskId = downloadTask.taskIdentifier
        let videoId = downloadTask.taskDescription ?? ""

        // Must copy file immediately — location is deleted after this method returns
        let tempDest = Self.downloadsDirectory.appendingPathComponent("\(videoId).bgdl")
        try? FileManager.default.removeItem(at: tempDest)
        try? FileManager.default.copyItem(at: location, to: tempDest)

        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let failed = statusCode < 200 || statusCode > 299

        Task { @MainActor in
            self.taskToVideoId.removeValue(forKey: taskId)
            self.videoIdToTaskId.removeValue(forKey: videoId)
            if failed {
                try? FileManager.default.removeItem(at: tempDest)
                self.handleDownloadCompletion(videoId: videoId, tempURL: nil, error: DownloadError.badResponse(statusCode))
            } else {
                self.handleDownloadCompletion(videoId: videoId, tempURL: tempDest, error: nil)
                try? FileManager.default.removeItem(at: tempDest)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskId = task.taskIdentifier
        let videoId = task.taskDescription ?? ""
        Task { @MainActor in
            self.taskToVideoId.removeValue(forKey: taskId)
            self.videoIdToTaskId.removeValue(forKey: videoId)
            self.handleDownloadCompletion(videoId: videoId, tempURL: nil, error: error)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let videoId = downloadTask.taskDescription ?? ""
        guard !videoId.isEmpty, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mapped = 0.1 + fraction * 0.85
        // Throttle: only update UI every ~5% to avoid flooding SwiftUI during large batches
        Task { @MainActor in
            let current = self.downloadProgress[videoId] ?? 0
            if mapped - current > 0.05 || mapped >= 0.95 {
                self.downloadProgress[videoId] = mapped
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.backgroundSessionCompletionHandler?()
            Self.backgroundSessionCompletionHandler = nil
        }
    }
}

enum DownloadError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Server error \(code)"
        }
    }
}
