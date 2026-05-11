import SwiftUI

struct SettingsView: View {
    @ObservedObject private var client = YTMusicClient.shared
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @State private var showLogoutConfirm = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Account card
                        SettingsSection(title: "Account") {
                            AccountRow(client: client)

                            if client.isAuthenticated {
                                Divider().background(Color.appBorder).padding(.horizontal, 14)

                                Button(action: { showLogoutConfirm = true }) {
                                    HStack {
                                        Image(systemName: "rectangle.portrait.and.arrow.right")
                                            .frame(width: 28)
                                            .foregroundStyle(.red)
                                        Text("Sign Out")
                                            .foregroundStyle(.red)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Watch card
                        SettingsSection(title: "Apple Watch") {
                            SettingsRow(
                                icon: "applewatch",
                                iconColor: sync.isAvailable ? Color.ytRed : Color.appFaint,
                                label: "Status",
                                value: sync.isAvailable
                                    ? (sync.isWatchReachable ? "Connected" : "Paired")
                                    : "Unavailable",
                                valueColor: sync.isAvailable ? Color.ytRed : Color.appFaint
                            )

                            Divider().background(Color.appBorder).padding(.horizontal, 14)

                            SettingsRow(
                                icon: "music.note",
                                iconColor: Color.appDim,
                                label: "Synced Tracks",
                                value: "\(sync.syncedTrackIds.count)"
                            )
                        }

                        // Storage card
                        SettingsSection(title: "Storage") {
                            SettingsRow(
                                icon: "internaldrive",
                                iconColor: .orange,
                                label: "Downloaded Tracks",
                                value: "\(downloader.downloadedTracks.count)"
                            )

                            if !downloader.downloadedTracks.isEmpty {
                                Divider().background(Color.appBorder).padding(.horizontal, 14)

                                Button(action: {
                                    for id in Array(downloader.downloadedTracks.keys) {
                                        downloader.deleteDownload(videoId: id)
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "trash")
                                            .frame(width: 28)
                                            .foregroundStyle(.red)
                                        Text("Clear All Downloads")
                                            .foregroundStyle(.red)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // About
                        SettingsSection(title: "About") {
                            SettingsRow(icon: "waveform", iconColor: Color.ytRed, label: "YTWatch", value: "1.0.0")
                            Divider().background(Color.appBorder).padding(.horizontal, 14)
                            SettingsRow(icon: "network", iconColor: .teal, label: "Audio Source", value: "Cobalt API")
                        }

                        Text("Audio cookies are stored in Keychain.\nApp is for personal use only.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appGhost)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Sign Out?", isPresented: $showLogoutConfirm) {
                Button("Sign Out", role: .destructive) { client.logout() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your saved cookies will be removed. You'll need to sign in again to sync playlists.")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
    }
}

// MARK: - Components

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .sectionHeader()
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .cardStyle()
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let value: String
    var valueColor: Color = Color.appFaint

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.white)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private struct AccountRow: View {
    @ObservedObject var client: YTMusicClient
    @State private var retrying = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                if let name = client.userDisplayName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Signed in to YouTube Music")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appFaint)
                } else if client.isAuthenticated {
                    Text("YouTube Music")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                    Text("Name not loaded")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appFaint)
                } else {
                    Text("Not signed in")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.appFaint)
                }
            }

            Spacer()

            if client.isAuthenticated {
                if retrying {
                    ProgressView().tint(Color.ytRed).scaleEffect(0.75)
                } else if client.userDisplayName == nil {
                    Button {
                        retrying = true
                        Task {
                            await client.fetchUserProfile()
                            retrying = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appFaint)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.ytRed)
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}
