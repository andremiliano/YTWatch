import SwiftUI

struct TrackListView: View {
    let playlist: Playlist
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var receiver = WatchFileReceiver.shared

    var body: some View {
        List {
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                Button(action: {
                    player.load(playlist: playlist, startAt: index)
                }) {
                    TrackListRow(track: track, isPlaying: player.currentTrack?.id == track.id && player.isPlaying)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let current = player.currentTrack, playlist.tracks.contains(where: { $0.id == current.id }) {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(destination: NowPlayingView()) {
                        MiniPlayerBar()
                    }
                }
            }
        }
    }
}

struct TrackListRow: View {
    let track: Track
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isPlaying {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .frame(width: 16)
                    .symbolEffect(.variableColor.iterative)
            } else {
                Text("")
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                    .lineLimit(2)
                    .foregroundStyle(isPlaying ? .red : .primary)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
