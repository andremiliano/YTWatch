import Foundation

// Messages passed over WatchConnectivity (context / sendMessage)
enum WatchMessageKey: String {
    case type
    case payload
}

enum WatchMessageType: String, Codable {
    case playlistIndex   // iPhone → Watch: updated playlist metadata
    case syncProgress    // iPhone → Watch: how many files transferred
    case playCommand     // Watch → iPhone: (future) play on phone
    case trackMetadata   // attached to each file transfer as metadata
    case deleteTrack     // iPhone → Watch: delete a track from watch
}

struct TrackTransferMetadata: Codable {
    let track: Track
    let playlistId: String
    let playlistTitle: String
    let indexInPlaylist: Int
}
