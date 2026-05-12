import Foundation
import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: String {
    case none, one, all

    var next: RepeatMode {
        switch self {
        case .none: return .all
        case .all:  return .one
        case .one:  return .none
        }
    }

    var sfSymbol: String {
        switch self {
        case .none, .all: return "repeat"
        case .one:        return "repeat.1"
        }
    }
}

@MainActor
final class WatchPlayer: ObservableObject {

    static let shared = WatchPlayer()

    @Published var currentTrack: Track?
    @Published var currentPlaylist: Playlist?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .none
    @Published var currentVolume: Float = 0.5

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var currentIndex = 0

    private var playQueue: [Int] = []
    private var queuePosition: Int = 0
    private var wasPlayingBeforeInterruption = false
    private var timeObserverTick = 0
    private var statusObservation: NSKeyValueObservation?
    // Incremented each time we start a new track — guards against stale async callbacks
    private var playbackGeneration: Int = 0
    private var sessionActivated = false

    // MARK: - Session setup

    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
        setupRemoteControls()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        restoreLastPlayed()
    }

    private func activateSessionAndPlay(url: URL, generation: Int) {
        if sessionActivated {
            beginPlayback(url: url, generation: generation)
            return
        }
        let session = AVAudioSession.sharedInstance()
        session.activate(options: []) { [weak self] success, activationError in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                guard success else {
                    self.error = "Audio activation failed: \(activationError?.localizedDescription ?? "unknown")"
                    self.isPlaying = false
                    return
                }
                self.sessionActivated = true
                self.beginPlayback(url: url, generation: generation)
            }
        }
    }

    func setVolume(_ vol: Float) {
        let clamped = max(0, min(1, vol))
        currentVolume = clamped
        player?.volume = clamped
    }

    // MARK: - Playback control

    func load(playlist: Playlist, startAt index: Int = 0) {
        currentPlaylist = playlist
        buildQueue(startingAt: index)
        playTrack(at: index)
    }

    func play() {
        guard player != nil else {
            // Player was torn down — re-initialize if we have a current track
            if let track = currentTrack,
               let url = WatchFileReceiver.shared.audioURL(for: track.videoId) {
                playbackGeneration += 1
                activateSessionAndPlay(url: url, generation: playbackGeneration)
            }
            return
        }
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
        advanceQueue(forward: true)
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else {
            advanceQueue(forward: false)
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        player?.seek(to: cmTime)
        currentTime = time
        updateNowPlaying()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        guard let playlist = currentPlaylist else { return }
        let current = currentIndex
        if isShuffled {
            var rest = Array(0..<playlist.tracks.count).filter { $0 != current }
            rest.shuffle()
            playQueue = [current] + rest
            queuePosition = 0
        } else {
            playQueue = Array(0..<playlist.tracks.count)
            queuePosition = current
        }
    }

    func toggleRepeat() {
        repeatMode = repeatMode.next
    }

    // MARK: - Private

    private func buildQueue(startingAt index: Int) {
        guard let playlist = currentPlaylist else { return }
        let count = playlist.tracks.count
        if isShuffled {
            var rest = Array(0..<count).filter { $0 != index }
            rest.shuffle()
            playQueue = [index] + rest
            queuePosition = 0
        } else {
            playQueue = Array(0..<count)
            queuePosition = index
        }
    }

    private func advanceQueue(forward: Bool) {
        guard !playQueue.isEmpty else { return }
        if forward {
            let next = queuePosition + 1
            if next < playQueue.count {
                queuePosition = next
                currentIndex = playQueue[queuePosition]
                playTrack(at: currentIndex)
            } else if repeatMode == .all {
                if let playlist = currentPlaylist {
                    buildQueue(startingAt: isShuffled ? Int.random(in: 0..<playlist.tracks.count) : 0)
                }
                currentIndex = playQueue[queuePosition]
                playTrack(at: currentIndex)
            }
        } else {
            let prev = queuePosition - 1
            if prev >= 0 {
                queuePosition = prev
                currentIndex = playQueue[queuePosition]
                playTrack(at: currentIndex)
            }
        }
    }

    private func playTrack(at index: Int) {
        guard let playlist = currentPlaylist,
              index >= 0, index < playlist.tracks.count else { return }

        let track = playlist.tracks[index]
        guard let url = WatchFileReceiver.shared.audioURL(for: track.videoId) else {
            error = "Track not downloaded: \(track.title)"
            // Skip to next available track
            skipUnavailable(from: index, forward: true)
            return
        }

        // Verify file is not empty/corrupt
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard fileSize > 1000 else {
            error = "Track file corrupt: \(track.title)"
            skipUnavailable(from: index, forward: true)
            return
        }

        tearDownPlayer()

        playbackGeneration += 1
        let gen = playbackGeneration

        currentIndex = index
        currentTrack = track
        error = nil
        duration = 0
        currentTime = 0

        // Update Now Playing immediately so it shows even before audio starts
        updateNowPlaying()

        activateSessionAndPlay(url: url, generation: gen)
    }

    private func skipUnavailable(from index: Int, forward: Bool) {
        guard let playlist = currentPlaylist else { return }
        let step = forward ? 1 : -1
        var nextIdx = index + step
        var tried = 0
        while nextIdx >= 0 && nextIdx < playlist.tracks.count && tried < playlist.tracks.count {
            let track = playlist.tracks[nextIdx]
            if WatchFileReceiver.shared.isAvailable(track.videoId) {
                playTrack(at: nextIdx)
                return
            }
            nextIdx += step
            tried += 1
        }
        // No available tracks — try shuffle to other playlists
        playNextPlaylist()
    }

    private func beginPlayback(url: URL, generation: Int) {
        guard playbackGeneration == generation else { return }

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let item = AVPlayerItem(asset: asset)
        playerItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        player = avPlayer

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        let capturedGen = generation
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let dur = observedItem.duration.seconds
            let errMsg = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == capturedGen,
                      self.playerItem === observedItem else { return }
                switch status {
                case .readyToPlay:
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    if !dur.isNaN && dur > 0 {
                        self.duration = dur
                    }
                    self.player?.play()
                    self.player?.volume = self.currentVolume
                    self.isPlaying = true
                    self.updateNowPlaying()
                    self.saveLastPlayed()
                case .failed:
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    let msg = errMsg ?? "Playback failed"
                    self.error = msg
                    self.isPlaying = false
                    print("[Player] \u{2717} \(self.currentTrack?.title ?? "?"): \(msg)")
                    // Auto-skip to next track on failure
                    self.advanceQueue(forward: true)
                default:
                    break
                }
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverTick = 0
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.playbackGeneration == capturedGen else { return }
                self.currentTime = time.seconds
                var needsNowPlayingUpdate = false
                if let d = self.playerItem?.duration.seconds, !d.isNaN, d > 0, abs(self.duration - d) > 0.5 {
                    self.duration = d
                    needsNowPlayingUpdate = true
                }
                self.timeObserverTick += 1
                if needsNowPlayingUpdate || self.timeObserverTick % 10 == 0 {
                    self.updateNowPlaying()
                }
                if self.timeObserverTick % 10 == 0 { self.saveLastPlayed() }
            }
        }
    }

    private func tearDownPlayer() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        player?.pause()
        player = nil
        playerItem = nil
    }

    @objc private func playerDidFinish() {
        Task { @MainActor in
            switch self.repeatMode {
            case .one:
                self.playTrack(at: self.currentIndex)
            case .all:
                self.advanceQueue(forward: true)
            case .none:
                let next = self.queuePosition + 1
                if next < self.playQueue.count {
                    self.queuePosition = next
                    self.currentIndex = self.playQueue[self.queuePosition]
                    self.playTrack(at: self.currentIndex)
                } else {
                    self.playNextPlaylist()
                }
            }
        }
    }

    private func playNextPlaylist() {
        let allPlaylists = WatchFileReceiver.shared.availablePlaylists
        guard !allPlaylists.isEmpty else {
            isPlaying = false
            currentTime = 0
            updateNowPlaying()
            return
        }

        let currentId = currentPlaylist?.id
        let currentIdx = allPlaylists.firstIndex(where: { $0.id == currentId }) ?? -1
        let nextIdx = (currentIdx + 1) % allPlaylists.count

        // If we wrapped around to the same playlist, stop (played everything once)
        if allPlaylists[nextIdx].id == currentId && allPlaylists.count == 1 {
            isPlaying = false
            currentTime = 0
            updateNowPlaying()
            return
        }

        let nextPlaylist = allPlaylists[nextIdx]
        currentPlaylist = nextPlaylist
        buildQueue(startingAt: 0)
        playTrack(at: 0)
    }

    // MARK: - Now Playing + Remote Controls

    private var cachedArtwork: (videoId: String, artwork: MPMediaItemArtwork)?

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
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
        if let artwork = artworkForCurrentTrack(track) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func artworkForCurrentTrack(_ track: Track) -> MPMediaItemArtwork? {
        if let cached = cachedArtwork, cached.videoId == track.videoId {
            return cached.artwork
        }
        guard let url = WatchFileReceiver.shared.thumbnailURL(for: track.videoId),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (track.videoId, artwork)
        return artwork
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

    // MARK: - Interruption Handling

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        Task { @MainActor in
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.isPlaying
                self.sessionActivated = false
                self.pause()
            case .ended:
                if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                        let gen = self.playbackGeneration
                        AVAudioSession.sharedInstance().activate(options: []) { [weak self] success, _ in
                            guard success else { return }
                            Task { @MainActor in
                                guard let self, self.playbackGeneration == gen else { return }
                                self.play()
                            }
                        }
                    }
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Route Change Handling

    private func setupRouteChangeHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        Task { @MainActor in
            if reason == .oldDeviceUnavailable {
                self.pause()
            }
        }
    }

    // MARK: - Last-Played Persistence

    private func saveLastPlayed() {
        guard let track = currentTrack, let playlist = currentPlaylist else { return }
        let state: [String: Any] = [
            "playlistId": playlist.id,
            "trackVideoId": track.videoId,
            "currentTime": currentTime,
            "currentIndex": currentIndex
        ]
        UserDefaults.standard.set(state, forKey: "lastPlayedState")
    }

    private func restoreLastPlayed() {
        guard let state = UserDefaults.standard.dictionary(forKey: "lastPlayedState"),
              let playlistId = state["playlistId"] as? String,
              let trackVideoId = state["trackVideoId"] as? String,
              let savedTime = state["currentTime"] as? Double,
              let savedIndex = state["currentIndex"] as? Int else { return }

        let playlists = WatchFileReceiver.shared.availablePlaylists
        guard let playlist = playlists.first(where: { $0.id == playlistId }),
              savedIndex < playlist.tracks.count,
              playlist.tracks[savedIndex].videoId == trackVideoId else { return }

        currentPlaylist = playlist
        currentIndex = savedIndex
        currentTrack = playlist.tracks[savedIndex]
        buildQueue(startingAt: savedIndex)
        duration = 0
        currentTime = savedTime
    }
}
