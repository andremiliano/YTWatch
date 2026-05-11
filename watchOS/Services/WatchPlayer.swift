import Foundation
import AVFoundation
import MediaPlayer

// Manages audio playback on the Apple Watch with background support.
@MainActor
final class WatchPlayer: ObservableObject {

    static let shared = WatchPlayer()

    @Published var currentTrack: Track?
    @Published var currentPlaylist: Playlist?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var currentIndex = 0

    // MARK: - Session setup (call once at app launch)

    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
        setupRemoteControls()
    }

    // MARK: - Playback control

    func load(playlist: Playlist, startAt index: Int = 0) {
        currentPlaylist = playlist
        currentIndex = index
        playTrack(at: index)
    }

    func play() {
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func next() {
        guard let playlist = currentPlaylist else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < playlist.tracks.count else { return }
        playTrack(at: nextIndex)
    }

    func previous() {
        // If >3s in, restart; else go to previous
        if currentTime > 3 {
            seek(to: 0)
        } else {
            let prevIndex = currentIndex - 1
            guard prevIndex >= 0 else { return }
            playTrack(at: prevIndex)
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        player?.seek(to: cmTime)
        currentTime = time
        updateNowPlaying()
    }

    // MARK: - Private

    private func playTrack(at index: Int) {
        guard let playlist = currentPlaylist,
              index >= 0, index < playlist.tracks.count else { return }

        let track = playlist.tracks[index]
        guard let url = WatchFileReceiver.shared.audioURL(for: track.videoId) else {
            error = "Track not downloaded: \(track.title)"
            return
        }

        // Tear down previous
        tearDownPlayer()

        currentIndex = index
        currentTrack = track
        error = nil

        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Observe end of track
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        // Time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds
                if let d = self.playerItem?.duration.seconds, !d.isNaN {
                    self.duration = d
                }
            }
        }

        player?.play()
        isPlaying = true
        duration = 0
        currentTime = 0

        updateNowPlaying()
    }

    private func tearDownPlayer() {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        player?.pause()
        player = nil
        playerItem = nil
    }

    @objc private func playerDidFinish() {
        Task { @MainActor in
            guard let playlist = self.currentPlaylist else { return }
            let nextIndex = self.currentIndex + 1
            if nextIndex < playlist.tracks.count {
                self.playTrack(at: nextIndex)
            } else {
                // End of playlist
                self.isPlaying = false
                self.currentTime = 0
            }
        }
    }

    // MARK: - Now Playing + Remote Controls

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: duration
        ]
        if let album = track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteControls() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }
}
