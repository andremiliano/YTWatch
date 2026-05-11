import Foundation
import WebKit

// Interfaces with YouTube Music's internal browsing API.
// Auth is handled by capturing cookies from a WKWebView Google login.
@MainActor
final class YTMusicClient: NSObject, ObservableObject {

    static let shared = YTMusicClient()

    @Published var isAuthenticated = false
    @Published var authError: String?

    private var authCookies: [HTTPCookie] = []

    // MARK: - Auth

    func loadSavedCookies() {
        guard let data = KeychainHelper.load(key: "ytm_cookies"),
              let decoded = try? JSONDecoder().decode([CookieArchive].self, from: data) else { return }
        authCookies = decoded.compactMap { $0.cookie }
        isAuthenticated = !authCookies.isEmpty
    }

    func saveCookies(_ cookies: [HTTPCookie]) {
        authCookies = cookies
        let archives = cookies.map { CookieArchive(cookie: $0) }
        if let data = try? JSONEncoder().encode(archives) {
            KeychainHelper.save(data, key: "ytm_cookies")
        }
        isAuthenticated = true
    }

    func logout() {
        authCookies = []
        KeychainHelper.delete(key: "ytm_cookies")
        isAuthenticated = false
    }

    // MARK: - API

    func fetchLibraryPlaylists() async throws -> [Playlist] {
        let body: [String: Any] = [
            "browseId": "FEmusic_library_privately_owned_playlists"
        ]
        let data = try await ytmRequest(endpoint: "browse", body: body)
        return try parsePlaylistsFromBrowse(data)
    }

    func fetchPlaylistTracks(playlistId: String) async throws -> [Track] {
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
        let body: [String: Any] = ["browseId": browseId]
        let data = try await ytmRequest(endpoint: "browse", body: body)
        return try parseTracksFromPlaylist(data)
    }

    // MARK: - HTTP

    private static var apiKey: String {
        Bundle.main.infoDictionary?["YTMAPIKey"] as? String ?? ""
    }

    private func ytmRequest(endpoint: String, body: [String: Any]) async throws -> Data {
        let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?key=\(Self.apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")

        // Attach auth cookies as header
        let cookieHeader = authCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        // Wrap body in standard YouTube Music context
        var fullBody = body
        fullBody["context"] = ytmContext()

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw YTMError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private func ytmContext() -> [String: Any] {
        [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20240101.01.00",
                "hl": "en",
                "gl": "US"
            ]
        ]
    }

    // MARK: - Parsing

    private func parsePlaylistsFromBrowse(_ data: Data) throws -> [Playlist] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid JSON root")
        }

        // Navigate: contents → singleColumnBrowseResultsRenderer → tabs[0] → tabRenderer
        // → content → sectionListRenderer → contents[] → gridRenderer → items[]
        // → musicTwoRowItemRenderer
        var playlists: [Playlist] = []

        func traverse(_ obj: Any, depth: Int = 0) {
            guard depth < 20 else { return }
            if let dict = obj as? [String: Any] {
                if let renderer = dict["musicTwoRowItemRenderer"] as? [String: Any] {
                    if let p = parsePlaylistRenderer(renderer) { playlists.append(p) }
                }
                for v in dict.values { traverse(v, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { traverse(item, depth: depth + 1) }
            }
        }
        traverse(json)

        // Deduplicate by id
        var seen = Set<String>()
        return playlists.filter { seen.insert($0.id).inserted }
    }

    private func parsePlaylistRenderer(_ r: [String: Any]) -> Playlist? {
        guard let titleObj = r["title"] as? [String: Any],
              let runs = titleObj["runs"] as? [[String: Any]],
              let title = runs.first?["text"] as? String else { return nil }

        guard let nav = r["navigationEndpoint"] as? [String: Any],
              let browse = nav["browseEndpoint"] as? [String: Any],
              let browseId = browse["browseId"] as? String else { return nil }

        let thumbRenderer = (r["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
        let thumbObj = thumbRenderer?["thumbnail"] as? [String: Any]
        let thumbnails = thumbObj?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnails?.last?["url"] as? String

        let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        return Playlist(id: playlistId, title: title, thumbnailURL: thumbnailURL, tracks: [])
    }

    private func parseTracksFromPlaylist(_ data: Data) throws -> [Track] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid JSON root")
        }

        var tracks: [Track] = []

        func traverse(_ obj: Any, depth: Int = 0) {
            guard depth < 25 else { return }
            if let dict = obj as? [String: Any] {
                if let renderer = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                    if let t = parseTrackRenderer(renderer) { tracks.append(t) }
                }
                for v in dict.values { traverse(v, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { traverse(item, depth: depth + 1) }
            }
        }
        traverse(json)

        return tracks
    }

    private func parseTrackRenderer(_ r: [String: Any]) -> Track? {
        guard let columns = r["flexColumns"] as? [[String: Any]] else { return nil }

        func text(column: Int) -> String? {
            let col = columns[safe: column]?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
            let textObj = col?["text"] as? [String: Any]
            let runs = textObj?["runs"] as? [[String: Any]]
            return runs?.first?["text"] as? String
        }

        guard let title = text(column: 0) else { return nil }
        let artist = text(column: 1) ?? "Unknown"
        let album = text(column: 2)

        let videoId: String?
        if let overlay = r["overlay"] as? [String: Any],
           let playButton = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = playButton["content"] as? [String: Any],
           let playBtn = content["musicPlayButtonRenderer"] as? [String: Any],
           let nav = playBtn["playNavigationEndpoint"] as? [String: Any],
           let watch = nav["watchEndpoint"] as? [String: Any] {
            videoId = watch["videoId"] as? String
        } else {
            videoId = nil
        }

        guard let vid = videoId else { return nil }

        var durationSeconds = 0
        if let fixed = r["fixedColumns"] as? [[String: Any]] {
            let fixedCol = fixed.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any]
            let fixedText = fixedCol?["text"] as? [String: Any]
            let fixedRuns = fixedText?["runs"] as? [[String: Any]]
            if let durText = fixedRuns?.first?["text"] as? String {
                durationSeconds = parseDuration(durText)
            }
        }

        let thumbRenderer = (r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
        let thumbObj = thumbRenderer?["thumbnail"] as? [String: Any]
        let thumbnails = thumbObj?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnails?.last?["url"] as? String

        return Track(
            id: vid,
            videoId: vid,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL
        )
    }

    private func parseDuration(_ s: String) -> Int {
        let parts = s.split(separator: ":").map { Int($0) ?? 0 }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return 0
    }
}

// MARK: - Errors

enum YTMError: LocalizedError {
    case httpError(Int)
    case parseError(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP \(code)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .notAuthenticated: return "Not logged in"
        }
    }
}

// MARK: - Cookie archiving (HTTPCookie isn't Codable)

private struct CookieArchive: Codable {
    let properties: [String: String]

    init(cookie: HTTPCookie) {
        var p: [String: String] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path
        ]
        if cookie.isSecure { p["secure"] = "TRUE" }
        properties = p
    }

    var cookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let n = properties["name"] { props[.name] = n }
        if let v = properties["value"] { props[.value] = v }
        if let d = properties["domain"] { props[.domain] = d }
        if let p = properties["path"] { props[.path] = p }
        return HTTPCookie(properties: props)
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
