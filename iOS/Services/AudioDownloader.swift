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

    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadedTracks: [String: URL] = [:]
    @Published var downloadErrors: [String: String] = [:]
    private(set) var trackMetadata: [String: TrackMeta] = [:]

    struct TrackMeta: Codable {
        let title: String
        let artist: String
        let thumbnailURL: String?
    }
    @Published var activeDownloadCount = 0
    @Published var totalQueuedCount = 0
    @Published var completedInBatch = 0
    @Published var estimatedSecondsRemaining: Double?

    // Maps videoId → Swift concurrency Task (for stream URL resolution phase)
    private var resolveTasks: [String: Task<URL, Error>] = [:]
    // Maps URLSessionDownloadTask.taskIdentifier → videoId
    private var taskToVideoId: [Int: String] = [:]
    // Continuations for callers awaiting download completion
    private var completionContinuations: [String: [CheckedContinuation<URL, Error>]] = [:]

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

    // MARK: - Public

    func download(track: Track, playlistId: String? = nil, playlistTitle: String? = nil) async throws -> URL {
        if let existing = downloadedTracks[track.videoId] { return existing }

        // If already resolving/downloading, wait for it
        if resolveTasks[track.videoId] != nil || taskToVideoId.values.contains(track.videoId) {
            return try await withCheckedThrowingContinuation { cont in
                completionContinuations[track.videoId, default: []].append(cont)
            }
        }

        downloadErrors.removeValue(forKey: track.videoId)
        trackMetadata[track.videoId] = TrackMeta(title: track.title, artist: track.artist, thumbnailURL: track.thumbnailURL)
        saveTrackMetadata()

        // Persist so we can resume if app is killed
        pendingDownloads[track.videoId] = PendingDownload(videoId: track.videoId, playlistId: playlistId, playlistTitle: playlistTitle)
        savePendingDownloads()

        let resolveTask = Task<URL, Error> {
            try await self.resolveAndStartBackgroundDownload(track: track, playlistId: playlistId, playlistTitle: playlistTitle)
        }
        resolveTasks[track.videoId] = resolveTask
        activeDownloadCount += 1

        do {
            let url = try await resolveTask.value
            return url
        } catch {
            resolveTasks.removeValue(forKey: track.videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            pendingDownloads.removeValue(forKey: track.videoId)
            savePendingDownloads()
            let msg = error.localizedDescription
            downloadErrors[track.videoId] = msg
            downloadProgress.removeValue(forKey: track.videoId)
            trackCompletion()
            print("[DL] \u{274c} \(track.title) (\(track.videoId)): \(msg)")
            throw error
        }
    }

    func cancelDownload(videoId: String) {
        resolveTasks[videoId]?.cancel()
        resolveTasks.removeValue(forKey: videoId)

        // Cancel any active background download task
        bgSession.getAllTasks { [weak self] tasks in
            for task in tasks {
                Task { @MainActor in
                    guard let self else { return }
                    if self.taskToVideoId[task.taskIdentifier] == videoId {
                        task.cancel()
                        self.taskToVideoId.removeValue(forKey: task.taskIdentifier)
                    }
                }
            }
        }

        downloadProgress.removeValue(forKey: videoId)
        pendingDownloads.removeValue(forKey: videoId)
        savePendingDownloads()
        activeDownloadCount = max(0, activeDownloadCount - 1)

        // Fail any waiting continuations
        if let conts = completionContinuations.removeValue(forKey: videoId) {
            for cont in conts { cont.resume(throwing: CancellationError()) }
        }
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

    func isDownloaded(_ videoId: String) -> Bool { downloadedTracks[videoId] != nil }
    func isDownloading(_ videoId: String) -> Bool {
        resolveTasks[videoId] != nil || taskToVideoId.values.contains(videoId)
    }
    var hasActiveDownloads: Bool {
        !resolveTasks.isEmpty || !taskToVideoId.isEmpty
    }
    func localURL(for videoId: String) -> URL? { downloadedTracks[videoId] }

    func deleteAllDownloads(for videoIds: [String]) {
        for id in videoIds { deleteDownload(videoId: id) }
    }

    func deleteAllDownloads() {
        let allIds = Array(downloadedTracks.keys)
        for id in allIds { deleteDownload(videoId: id) }
    }

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

    func beginBatch(total: Int) {
        totalQueuedCount = total
        completedInBatch = 0
        batchStartTime = Date()
        batchStartCompleted = 0
        estimatedSecondsRemaining = nil
        beginBackgroundTask()
    }

    func endBatch() {
        totalQueuedCount = 0
        completedInBatch = 0
        estimatedSecondsRemaining = nil
        batchStartTime = nil
        endBackgroundTask()
    }

    // MARK: - Background Download Flow

    private func resolveAndStartBackgroundDownload(track: Track, playlistId: String?, playlistTitle: String?) async throws -> URL {
        guard Self.isValidVideoId(track.videoId) else {
            throw DownloadError.badResponse(-1)
        }
        let destURL = Self.downloadsDirectory.appendingPathComponent("\(track.videoId).m4a")
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL
        }

        downloadProgress[track.videoId] = 0.02

        // Phase 1: Resolve stream URL (foreground, fast)
        let streamURL = try await YTMusicClient.shared.fetchAudioStreamURL(videoId: track.videoId)
        downloadProgress[track.videoId] = 0.1

        // Phase 2: Start background download task
        let request = Self.buildStreamRequest(streamURL: streamURL)
        print("[DL] BG download \(streamURL.host ?? "") for \(track.videoId)")

        let downloadTask = bgSession.downloadTask(with: request)
        downloadTask.taskDescription = track.videoId
        taskToVideoId[downloadTask.taskIdentifier] = track.videoId
        downloadTask.resume()

        resolveTasks.removeValue(forKey: track.videoId)

        // Wait for background session delegate to deliver the file
        return try await withCheckedThrowingContinuation { cont in
            completionContinuations[track.videoId, default: []].append(cont)
        }
    }

    private static func buildStreamRequest(streamURL: URL) -> URLRequest {
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

    // Called when background download completes — moves file to final location
    private func handleDownloadCompletion(videoId: String, tempURL: URL?, error: Error?) {
        let pendingInfo = pendingDownloads[videoId]
        pendingDownloads.removeValue(forKey: videoId)
        savePendingDownloads()

        if let error {
            let msg = error.localizedDescription
            downloadErrors[videoId] = msg
            downloadProgress.removeValue(forKey: videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            trackCompletion()
            print("[DL] \u{274c} \(videoId): \(msg)")
            if let conts = completionContinuations.removeValue(forKey: videoId) {
                for cont in conts { cont.resume(throwing: error) }
            }
            return
        }

        guard let tempURL else {
            let err = DownloadError.badResponse(-1)
            downloadErrors[videoId] = err.localizedDescription
            downloadProgress.removeValue(forKey: videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            trackCompletion()
            if let conts = completionContinuations.removeValue(forKey: videoId) {
                for cont in conts { cont.resume(throwing: err) }
            }
            return
        }

        let destURL = Self.downloadsDirectory.appendingPathComponent("\(videoId).m4a")
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            downloadErrors[videoId] = error.localizedDescription
            downloadProgress.removeValue(forKey: videoId)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            trackCompletion()
            if let conts = completionContinuations.removeValue(forKey: videoId) {
                for cont in conts { cont.resume(throwing: error) }
            }
            return
        }

        downloadedTracks[videoId] = destURL
        downloadProgress[videoId] = 1.0
        activeDownloadCount = max(0, activeDownloadCount - 1)
        trackCompletion()
        print("[DL] \u{2713} \(videoId)")

        // Auto-sync to watch
        if let meta = trackMetadata[videoId] {
            let track = Track(
                id: videoId, videoId: videoId, title: meta.title,
                artist: meta.artist, album: nil, durationSeconds: 0,
                thumbnailURL: meta.thumbnailURL
            )
            if let pid = pendingInfo?.playlistId, let ptitle = pendingInfo?.playlistTitle {
                WatchSyncManager.shared.queueTrackForSync(track, fileURL: destURL, playlistId: pid, playlistTitle: ptitle)
            }
        }

        if let conts = completionContinuations.removeValue(forKey: videoId) {
            for cont in conts { cont.resume(returning: destURL) }
        }
    }

    // On init, check if background session has outstanding tasks from a previous launch
    private func reconcileBackgroundTasks() {
        bgSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    if let videoId = task.taskDescription, !videoId.isEmpty {
                        self.taskToVideoId[task.taskIdentifier] = videoId
                        if self.downloadProgress[videoId] == nil {
                            self.downloadProgress[videoId] = 0.1
                        }
                    }
                }
                self.activeDownloadCount = self.resolveTasks.count + self.taskToVideoId.count
            }
        }
    }

    // MARK: - Background Task (for URL resolution phase)

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
                // Clear from pending if already completed
                pendingDownloads.removeValue(forKey: videoId)
            } else if file.pathExtension == "tmp" {
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
            self.handleDownloadCompletion(videoId: videoId, tempURL: nil, error: error)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let videoId = downloadTask.taskDescription ?? ""
        guard !videoId.isEmpty, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Map to 0.1–0.95 range (0.0–0.1 is URL resolution, 0.95–1.0 is file move)
        let mapped = 0.1 + fraction * 0.85
        Task { @MainActor in
            self.downloadProgress[videoId] = mapped
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
