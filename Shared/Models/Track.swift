import Foundation

struct Track: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    let durationSeconds: Int
    let thumbnailURL: String?

    // Transient — not synced to watch
    var isDownloadedOnPhone: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, videoId, title, artist, album, durationSeconds, thumbnailURL
    }

    var durationFormatted: String {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
