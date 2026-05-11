import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results = YTMusicClient.SearchResults()
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(focused ? Color.ytRed : Color.appFaint)

                            TextField("Songs, albums, artists…", text: $query)
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .tint(Color.ytRed)
                                .focused($focused)
                                .submitLabel(.search)
                                .onSubmit { runSearch() }

                            if !query.isEmpty {
                                Button { query = ""; results = YTMusicClient.SearchResults(); hasSearched = false } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.appFaint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(focused ? Color.ytRed.opacity(0.5) : Color.appBorder, lineWidth: 0.5)
                        )
                        .animation(.easeInOut(duration: 0.15), value: focused)

                        if focused {
                            Button("Cancel") {
                                query = ""
                                focused = false
                                results = YTMusicClient.SearchResults()
                                hasSearched = false
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.ytRed)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)

                    if isSearching {
                        Spacer()
                        ProgressView().tint(Color.ytRed)
                        Spacer()
                    } else if !hasSearched {
                        SearchSuggestionsView(onTap: { q in query = q; runSearch() })
                    } else if results.songs.isEmpty && results.albums.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40, weight: .ultraLight))
                                .foregroundStyle(Color.appGhost)
                            Text("No results for \"\(query)\"")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.appDim)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                if !results.albums.isEmpty {
                                    SearchSection(title: "Albums & Singles") {
                                        ForEach(results.albums) { album in
                                            NavigationLink(destination: PlaylistDetailView(playlist: album)) {
                                                SearchAlbumRow(album: album)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                if !results.songs.isEmpty {
                                    SearchSection(title: "Songs") {
                                        ForEach(results.songs) { song in
                                            TrackRow(track: song)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    private func runSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        focused = false
        isSearching = true
        hasSearched = true
        Task {
            do {
                results = try await YTMusicClient.shared.search(query: query)
            } catch {
                self.error = error.localizedDescription
            }
            isSearching = false
        }
    }
}

// MARK: - Section wrapper

private struct SearchSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .sectionHeader()
                .padding(.leading, 4)
            VStack(spacing: 2) { content }
        }
    }
}

// MARK: - Album row

private struct SearchAlbumRow: View {
    let album: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared

    private var downloadedCount: Int {
        album.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            ThumbnailView(url: album.thumbnailURL, size: 56, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Album")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appFaint)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Suggestions

private struct SearchSuggestionsView: View {
    let onTap: (String) -> Void

    private let suggestions = [
        ("waveform", "Discover new music"),
        ("flame", "Top charts"),
        ("heart", "Liked artists"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(Color.appGhost)

                Text("Search YouTube Music")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appDim)

                Text("Find songs and albums to download directly to your Apple Watch.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }
}
