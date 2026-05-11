import SwiftUI

struct NowPlayingView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @State private var crownValue: Double = 0

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(player.currentTime / player.duration, 1.0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Subtle red ambient glow behind ring
            RadialGradient(
                colors: [Color.ytRed.opacity(0.08), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 90
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                // Track info
                VStack(spacing: 2) {
                    Text(player.currentTrack?.title ?? "Nothing Playing")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(player.currentTrack?.artist ?? "")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                Spacer(minLength: 4)

                // Ring + controls
                ZStack {
                    // Track ring background
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 4)

                    // Progress arc
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            Color.ytRed,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.4), value: progress)

                    // Play/Pause button
                    Button(action: { player.togglePlayPause() }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.05))
                                .frame(width: 50, height: 50)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .offset(x: player.isPlaying ? 0 : 1.5) // optical center for play icon
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 88, height: 88)
                .focusable()
                .digitalCrownRotation(
                    Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    from: 0,
                    through: max(player.duration, 1),
                    by: 3,
                    sensitivity: .medium
                )

                Spacer(minLength: 4)

                // Time + skip row
                HStack(alignment: .center) {
                    Button(action: { player.previous() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.55))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(spacing: 0) {
                        Text(formatTime(player.currentTime))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                    }

                    Spacer()

                    Button(action: { player.next() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(white: 0.55))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, !seconds.isNaN else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
