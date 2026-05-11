import Foundation

// Downloads audio via the Cobalt public API (https://cobalt.tools).
// No Mac server needed — works from anywhere with internet.
@MainActor
final class AudioDownloader: ObservableObject {

    static let shared = AudioDownloader()

    @Published var downloadProgress: [String: Double] = [:]   // videoId → 0.0–1.0
    @Published var downloadedTracks: [String: URL] = [:]       // videoId → local file URL
    @Published var failedTracks: Set<String> = []

    private var activeTasks: [String: Task<URL, Error>] = [:]

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    init() {
        createDownloadsDirectory()
        scanExistingDownloads()
    }

    // MARK: - Public

    func download(track: Track) async throws -> URL {
        if let existing = downloadedTracks[track.videoId] { return existing }

        if let running = activeTasks[track.videoId] { return try await running.value }

        let task = Task<URL, Error> { try await self.performDownload(track: track) }
        activeTasks[track.videoId] = task
        defer { activeTasks.removeValue(forKey: track.videoId) }

        do {
            let url = try await task.value
            downloadedTracks[track.videoId] = url
            downloadProgress[track.videoId] = 1.0
            return url
        } catch {
            failedTracks.insert(track.videoId)
            downloadProgress.removeValue(forKey: track.videoId)
            throw error
        }
    }

    func cancelDownload(videoId: String) {
        activeTasks[videoId]?.cancel()
        activeTasks.removeValue(forKey: videoId)
        downloadProgress.removeValue(forKey: videoId)
    }

    func deleteDownload(videoId: String) {
        if let url = downloadedTracks[videoId] {
            try? FileManager.default.removeItem(at: url)
            downloadedTracks.removeValue(forKey: videoId)
        }
        downloadProgress.removeValue(forKey: videoId)
        failedTracks.remove(videoId)
    }

    func isDownloaded(_ videoId: String) -> Bool { downloadedTracks[videoId] != nil }
    func localURL(for videoId: String) -> URL? { downloadedTracks[videoId] }

    // MARK: - Private

    private func performDownload(track: Track) async throws -> URL {
        let destURL = Self.downloadsDirectory.appendingPathComponent("\(track.videoId).m4a")
        if FileManager.default.fileExists(atPath: destURL.path) { return destURL }

        downloadProgress[track.videoId] = 0.05

        // Step 1: ask Cobalt for a direct audio stream URL
        let streamURL = try await cobaltResolve(videoId: track.videoId)

        downloadProgress[track.videoId] = 0.15

        // Step 2: download the stream
        let (tempURL, response) = try await URLSession.shared.download(from: streamURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloadError.badResponse
        }

        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        return destURL
    }

    // Calls the Cobalt API and returns a direct download URL for the audio.
    private func cobaltResolve(videoId: String) async throws -> URL {
        let apiURL = URL(string: "https://api.cobalt.tools/")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "url": "https://www.youtube.com/watch?v=\(videoId)",
            "downloadMode": "audio",
            "audioFormat": "m4a",
            "audioBitrate": "128"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.cobaltError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.cobaltError("invalid response")
        }

        // status: "tunnel" or "redirect" both give a usable URL
        guard let status = json["status"] as? String, status != "error" else {
            let errDetail = (json["error"] as? [String: Any])?["code"] as? String ?? "unknown"
            throw DownloadError.cobaltError(errDetail)
        }

        guard let urlString = json["url"] as? String, let url = URL(string: urlString) else {
            throw DownloadError.cobaltError("no URL in response")
        }

        return url
    }

    private func createDownloadsDirectory() {
        try? FileManager.default.createDirectory(at: Self.downloadsDirectory, withIntermediateDirectories: true)
    }

    private func scanExistingDownloads() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.downloadsDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "m4a" {
            let videoId = file.deletingPathExtension().lastPathComponent
            downloadedTracks[videoId] = file
            downloadProgress[videoId] = 1.0
        }
    }
}

enum DownloadError: LocalizedError {
    case badResponse
    case cobaltError(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Bad response from server"
        case .cobaltError(let msg): return "Cobalt: \(msg)"
        }
    }
}
