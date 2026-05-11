import SwiftUI

struct NowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @Environment(\.dismiss) private var dismiss

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    var body: some View {
        VStack(spacing: 0) {
            // Track info
            VStack(spacing: 2) {
                Text(player.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(player.currentTrack?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            Spacer(minLength: 4)

            // Progress ring + time
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)

                VStack(spacing: 1) {
                    Text(formatTime(player.currentTime))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                    Text(formatTime(player.duration))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 80)
            .padding(.vertical, 4)
            // Digital Crown scrubs timeline
            .focusable()
            .digitalCrownRotation(
                Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                from: 0,
                through: max(player.duration, 1),
                by: 5,
                sensitivity: .medium
            )

            Spacer(minLength: 4)

            // Controls
            HStack(spacing: 16) {
                Button(action: { player.previous() }) {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)

                Button(action: { player.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            .padding(.bottom, 4)
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, !seconds.isNaN else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
