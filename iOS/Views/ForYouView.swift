import SwiftUI

// MARK: - Store

@MainActor
final class ForYouStore: ObservableObject {
    static let shared = ForYouStore()

    @Published var likedSongs: Playlist?
    @Published var homeMixes: [Playlist] = []
    @Published var isLoading = false
    @Published var error: String?

    func refresh() async {
        guard YTMusicClient.shared.isAuthenticated, !isLoading else { return }
        isLoading = true
        error = nil

        async let likedTask: Void = fetchLiked()
        async let mixesTask: Void = fetchMixes()
        _ = await (likedTask, mixesTask)

        isLoading = false
    }

    private func fetchLiked() async {
        let tracks = (try? await YTMusicClient.shared.fetchLikedSongs()) ?? []
        likedSongs = Playlist(
            id: "VLSE",
            title: "Liked Songs",
            thumbnailURL: nil,
            tracks: tracks
        )
    }

    private func fetchMixes() async {
        do {
            homeMixes = try await YTMusicClient.shared.fetchHomeFeed()
        } catch {
            if likedSongs == nil { self.error = error.localizedDescription }
        }
    }
}

// MARK: - View

struct ForYouView: View {
    @ObservedObject private var store = ForYouStore.shared
    @ObservedObject private var client = YTMusicClient.shared
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                if store.isLoading && store.likedSongs == nil && store.homeMixes.isEmpty {
                    ProgressView()
                        .tint(Color.ytRed)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            // Liked Songs card
                            if let liked = store.likedSongs {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Your Music")
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    NavigationLink(destination: PlaylistDetailView(playlist: liked)) {
                                        LikedSongsCard(playlist: liked)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 10)
                            }

                            // Home feed mixes
                            if !store.homeMixes.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Recommended For You")
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    ForEach(Array(store.homeMixes.enumerated()), id: \.element.id) { i, mix in
                                        NavigationLink(destination: PlaylistDetailView(playlist: mix)) {
                                            MixRow(playlist: mix)
                                        }
                                        .buttonStyle(.plain)
                                        .opacity(appeared ? 1 : 0)
                                        .offset(y: appeared ? 0 : 10)
                                        .animation(
                                            .spring(response: 0.45, dampingFraction: 0.82)
                                                .delay(0.05 + Double(i) * 0.035),
                                            value: appeared
                                        )
                                    }
                                }
                            }

                            if store.likedSongs == nil && store.homeMixes.isEmpty && !store.isLoading {
                                EmptyForYouView()
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle(forYouTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Error", isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            )) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .task { if store.likedSongs == nil { await store.refresh() } }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
    }

    private var forYouTitle: String {
        if let name = client.userDisplayName, !name.isEmpty {
            let first = name.components(separatedBy: " ").first ?? name
            return "For \(first)"
        }
        return "For You"
    }
}

// MARK: - Liked Songs Card

private struct LikedSongsCard: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared

    private var downloadedCount: Int {
        playlist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.ytRed, Color.ytRed.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                Image(systemName: "heart.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Liked Songs")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                if playlist.tracks.isEmpty {
                    Text("Tap to load")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)
                } else {
                    Text("\(playlist.tracks.count) songs")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)

                    if downloadedCount > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color.ytRed).frame(width: 5, height: 5)
                            Text("\(downloadedCount) downloaded")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.ytRed.opacity(0.9))
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.ytRed.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Mix Row

private struct MixRow: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared

    private var downloadedCount: Int {
        playlist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            ThumbnailView(url: playlist.thumbnailURL, size: 56, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if playlist.trackCount > 0 {
                    Text("\(playlist.trackCount) tracks")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)
                } else {
                    Text("Tap to load")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)
                }
            }

            Spacer()

            if downloadedCount > 0 && downloadedCount == playlist.trackCount {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ytRed)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Empty State

private struct EmptyForYouView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Color.appGhost)
            Text("Nothing here yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.appDim)
            Text("Pull to refresh or check your connection.")
                .font(.system(size: 13))
                .foregroundStyle(Color.appFaint)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
    }
}
