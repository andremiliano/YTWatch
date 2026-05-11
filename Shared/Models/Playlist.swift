import Foundation

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let thumbnailURL: String?
    var tracks: [Track]

    var trackCount: Int { tracks.count }

    var totalDurationSeconds: Int {
        tracks.reduce(0) { $0 + $1.durationSeconds }
    }
}
