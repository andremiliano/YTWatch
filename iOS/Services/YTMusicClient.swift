import Foundation
import WebKit
import CryptoKit

// Interfaces with YouTube Music's internal browsing API.
// Auth is handled by capturing cookies from a WKWebView Google login.
@MainActor
final class YTMusicClient: NSObject, ObservableObject {

    static let shared = YTMusicClient()

    @Published var isAuthenticated = false
    @Published var userDisplayName: String?
    @Published var authError: String?

    private var authCookies: [HTTPCookie] = []
    private var visitorData: String = ""

    // MARK: - Auth

    func loadSavedCookies() {
        guard let data = KeychainHelper.load(key: "ytm_cookies"),
              let decoded = try? JSONDecoder().decode([CookieArchive].self, from: data) else { return }
        authCookies = decoded.compactMap { $0.cookie }
        isAuthenticated = !authCookies.isEmpty
        userDisplayName = UserDefaults.standard.string(forKey: "ytm_display_name")
        if isAuthenticated {
            Task { await refreshSessionData() }
        }
    }

    func saveCookies(_ cookies: [HTTPCookie]) {
        authCookies = cookies
        let archives = cookies.map { CookieArchive(cookie: $0) }
        if let data = try? JSONEncoder().encode(archives) {
            KeychainHelper.save(data, key: "ytm_cookies")
        }
        isAuthenticated = true
        Task { await refreshSessionData() }
    }

    private func refreshSessionData() async {
        await fetchVisitorData()
        await fetchUserProfile()
    }

    // Fetches visitorData from the YTM home page — required in all API requests.
    private func fetchVisitorData() async {
        var req = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            print("[YTM] fetchVisitorData: failed to load home page")
            return
        }

        // Extract VISITOR_DATA from ytcfg embedded in the page
        if let regex = try? NSRegularExpression(pattern: #""VISITOR_DATA"\s*:\s*"([^"]+)""#),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            visitorData = String(html[range])
            print("[YTM] visitorData ok: \(visitorData.prefix(16))…")
        } else {
            print("[YTM] visitorData: not found in page HTML")
        }
    }

    func logout() {
        authCookies = []
        userDisplayName = nil
        KeychainHelper.delete(key: "ytm_cookies")
        UserDefaults.standard.removeObject(forKey: "ytm_display_name")
        isAuthenticated = false
    }

    // Fetches the signed-in account name to confirm cookies are valid.
    func fetchUserProfile() async {
        guard let name = await fetchAccountName() else { return }
        userDisplayName = name
        UserDefaults.standard.set(name, forKey: "ytm_display_name")
    }

    private func fetchAccountName() async -> String? {
        // Try account_menu first (most reliable for display name)
        if let data = try? await ytmRequest(endpoint: "account/account_menu", body: [:]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = extractAccountName(from: json) { return name }
        }
        // Fallback: account/get_setting
        if let data = try? await ytmRequest(endpoint: "account/get_setting", body: [:]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = extractAccountName(from: json) { return name }
        }
        return nil
    }

    private func extractAccountName(from json: [String: Any]) -> String? {
        // Walk entire JSON tree looking for "channelHandle", "displayName", or text runs
        // inside account-related renderer keys
        func walk(_ obj: Any) -> String? {
            if let dict = obj as? [String: Any] {
                // Direct string fields
                for key in ["channelName", "displayName", "title"] {
                    if let s = dict[key] as? String, !s.isEmpty { return s }
                }
                // runs[].text pattern
                if let runs = dict["runs"] as? [[String: Any]],
                   let text = runs.first?["text"] as? String, !text.isEmpty {
                    return text
                }
                for v in dict.values { if let found = walk(v) { return found } }
            } else if let arr = obj as? [Any] {
                for item in arr { if let found = walk(item) { return found } }
            }
            return nil
        }

        // Look specifically inside account-header-like keys first
        for key in ["header", "accountName", "accountSectionHeaderRenderer",
                    "activeAccountHeaderRenderer", "accountItemSectionRenderer"] {
            if let sub = json[key] { if let name = walk(sub) { return name } }
        }
        return nil
    }

    // MARK: - API

    func fetchLibraryPlaylists() async throws -> [Playlist] {
        // Primary: liked/saved playlists (most reliable endpoint)
        // Secondary: privately owned playlists (may not exist for all accounts — swallow errors)
        let likedData = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_liked_playlists"])
        let ownedData = try? await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_library_privately_owned_playlists"])

        var playlists = (try? parsePlaylistsFromBrowse(likedData)) ?? []
        var seen = Set(playlists.map(\.id))

        if let owned = ownedData, let batch = try? parsePlaylistsFromBrowse(owned) {
            for p in batch where seen.insert(p.id).inserted { playlists.append(p) }
        }
        return playlists
    }

    func fetchPlaylistTracks(playlistId: String) async throws -> [Track] {
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
        let body: [String: Any] = ["browseId": browseId]
        let data = try await ytmRequest(endpoint: "browse", body: body)
        return try parseTracksFromPlaylist(data)
    }

    // MARK: - HTTP

    private func ytmRequest(endpoint: String, body: [String: Any]) async throws -> Data {
        let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")

        // Cookie header
        request.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        print("[YTM] cookies: \(authCookies.map(\.name).joined(separator: ", "))")

        // SAPISIDHASH — required by YouTube Music API.
        // Newer Google accounts may only have __Secure-3PAPISID, not SAPISID.
        let sapisid = authCookies.first(where: { $0.name == "SAPISID" })?.value
                   ?? authCookies.first(where: { $0.name == "__Secure-3PAPISID" })?.value
        if let sapisid {
            request.setValue(generateSAPISIDHASH(sapisid: sapisid), forHTTPHeaderField: "Authorization")
        }

        // Wrap body in standard YouTube Music context
        var fullBody = body
        fullBody["context"] = ytmContext()

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[YTM] \(status) on \(endpoint) — \(body.prefix(400))")
            throw YTMError.httpError(status)
        }
        return data
    }

    private func generateSAPISIDHASH(sapisid: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let message = "\(timestamp) \(sapisid) https://music.youtube.com"
        let digest = Insecure.SHA1.hash(data: Data(message.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    private func cookieHeader() -> String {
        authCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func ytmContext() -> [String: Any] {
        let datePart = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date())
        }()
        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": "1.\(datePart).01.00",
            "hl": "en",
            "gl": "US",
            "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36,gzip(gfe)"
        ]
        if !visitorData.isEmpty { client["visitorData"] = visitorData }
        return [
            "client": client,
            "user": ["lockedSafetyMode": false],
            "request": ["useSsl": true, "internalExperimentFlags": [Any]()]
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
