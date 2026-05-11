import SwiftUI

struct PlaylistListView: View {
    @ObservedObject private var receiver = WatchFileReceiver.shared
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if receiver.availablePlaylists.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 28, weight: .ultraLight))
                            .foregroundStyle(Color(white: 0.25))
                        Text("No music yet")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(white: 0.6))
                        Text("Sync a playlist from the iPhone app.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.3))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            // Now playing bar
                            if let track = player.currentTrack {
                                NavigationLink(destination: NowPlayingView()) {
                                    NowPlayingBanner(track: track)
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(receiver.availablePlaylists) { playlist in
                                NavigationLink(destination: TrackListView(playlist: playlist)) {
                                    WatchPlaylistRow(playlist: playlist)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("YTWatch")
            .overlay(alignment: .bottomTrailing) {
                if receiver.receivingCount > 0 {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6).tint(Color.ytRed)
                        Text("Syncing")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.08))
                    .clipShape(Capsule())
                    .padding(8)
                }
            }
        }
    }
}

private struct NowPlayingBanner: View {
    let track: Track
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.ytRed)
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.45))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(white: 0.25))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.ytRed.opacity(0.15), Color(white: 0.07)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.ytRed.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct WatchPlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(playlist.tracks.count) tracks")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.38))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(white: 0.2))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
