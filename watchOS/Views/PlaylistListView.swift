import SwiftUI

struct PlaylistListView: View {
    @ObservedObject private var receiver = WatchFileReceiver.shared
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        NavigationStack {
            Group {
                if receiver.availablePlaylists.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No music yet")
                            .font(.headline)
                        Text("Open YTWatch on your iPhone and sync a playlist.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(receiver.availablePlaylists) { playlist in
                        NavigationLink(destination: TrackListView(playlist: playlist)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text("\(playlist.tracks.count) tracks")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("YTWatch")
            .navigationBarTitleDisplayMode(.large)
            // Receiving indicator
            .overlay(alignment: .bottomTrailing) {
                if receiver.receivingCount > 0 {
                    Label("Syncing", systemImage: "arrow.down.circle.fill")
                        .font(.caption2)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            }
            // Tap bottom bar to go to now playing
            .toolbar {
                if player.currentTrack != nil {
                    ToolbarItem(placement: .bottomBar) {
                        NavigationLink(destination: NowPlayingView()) {
                            MiniPlayerBar()
                        }
                    }
                }
            }
        }
    }
}

struct MiniPlayerBar: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.caption)
            Text(player.currentTrack?.title ?? "")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
    }
}
