import SwiftUI

struct DownloadsListView: View {
    @ObservedObject private var downloader = AudioDownloader.shared
    @State private var showClearAllConfirm = false

    private var downloadedIds: [String] {
        Array(downloader.downloadedTracks.keys).sorted()
    }

    private var totalSize: String {
        let bytes = downloadedIds.compactMap { downloader.downloadedTracks[$0] }
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
            .reduce(0, +)
        if bytes < 1_048_576 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            if downloadedIds.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(Color.appGhost)
                    Text("No Downloads")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appDim)
                    Text("Downloaded tracks will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appFaint)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(downloadedIds.count) tracks")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.appFaint)
                            Text("·")
                                .foregroundStyle(Color.appGhost)
                            Text(totalSize)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.appFaint)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                        LazyVStack(spacing: 1) {
                            ForEach(downloadedIds, id: \.self) { videoId in
                                DownloadedTrackRow(videoId: videoId)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.appBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !downloadedIds.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .alert("Clear All Downloads?", isPresented: $showClearAllConfirm) {
            Button("Delete All", role: .destructive) {
                downloader.deleteAllDownloads(for: downloadedIds)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(downloadedIds.count) downloaded tracks (\(totalSize)).")
        }
    }
}

private struct DownloadedTrackRow: View {
    let videoId: String
    @ObservedObject private var downloader = AudioDownloader.shared

    private var meta: AudioDownloader.TrackMeta? { downloader.trackMetadata[videoId] }

    private var fileSize: String {
        guard let url = downloader.downloadedTracks[videoId],
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int else { return "" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: meta?.thumbnailURL, size: 42, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(meta?.title ?? videoId)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let artist = meta?.artist {
                        Text(artist)
                            .lineLimit(1)
                    }
                    if !fileSize.isEmpty {
                        Text("·")
                        Text(fileSize)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.appFaint)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    downloader.deleteDownload(videoId: videoId)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
