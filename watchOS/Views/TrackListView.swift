import SwiftUI

struct TrackListView: View {
    let playlist: Playlist
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                        Button(action: { player.load(playlist: playlist, startAt: index) }) {
                            WatchTrackRow(
                                track: track,
                                isActive: player.currentTrack?.id == track.id
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Open now playing if something is playing from this playlist
                    if let current = player.currentTrack,
                       playlist.tracks.contains(where: { $0.id == current.id }) {
                        NavigationLink(destination: NowPlayingView()) {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.ytRed)
                                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                Text("Now Playing")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.ytRed)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.ytRed.opacity(0.08))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchTrackRow: View {
    let track: Track
    let isActive: Bool
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        HStack(spacing: 8) {
            // Active indicator
            ZStack {
                if isActive {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ytRed)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                } else {
                    Circle()
                        .fill(Color(white: 0.2))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12, weight: isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? Color.ytRed : .white)
                    .lineLimit(2)
                Text(track.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: isActive ? 0.5 : 0.35))
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(white: 0.25))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isActive ? Color.ytRed.opacity(0.1) : Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? Color.ytRed.opacity(0.3) : Color.clear, lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}
