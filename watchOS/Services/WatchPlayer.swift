import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import WatchKit
import ImageIO

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

struct RecentPlay: Codable, Identifiable {
    var id: String { trackVideoId }
    let trackVideoId: String
    let trackTitle: String
    let trackArtist: String
    let trackDurationSeconds: Int
    let playlistId: String
    let playlistTitle: String
    let date: Date

    init(track: Track, playlistId: String, playlistTitle: String, date: Date) {
        self.trackVideoId = track.videoId
        self.trackTitle = track.title
        self.trackArtist = track.artist
        self.trackDurationSeconds = track.durationSeconds
        self.playlistId = playlistId
        self.playlistTitle = playlistTitle
        self.date = date
    }

    var asTrack: Track {
        Track(id: trackVideoId, videoId: trackVideoId, title: trackTitle, artist: trackArtist, durationSeconds: trackDurationSeconds)
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

    // Sleep timer
    @Published var sleepTimerRemaining: TimeInterval? = nil
    private var sleepTimer: Timer?
    private var sleepTimerTarget: Date? // absolute target time — survives background

    // Track change toast
    @Published var trackChangeToast: Track? = nil

    // Recently played tracking
    @Published var recentlyPlayed: [RecentPlay] = []
    private static let maxRecentPlays = 50

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var currentIndex = 0

    private var playQueue: [Int] = []
    private var queuePosition: Int = 0
    private var wasPlayingBeforeInterruption = false
    private var timeObserverTick = 0
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    // Incremented each time we start a new track — guards against stale async callbacks
    private var playbackGeneration: Int = 0
    private var sessionActivated = false
    // Stall detection — catches tracks where container duration > actual audio
    private var lastObservedTime: Double = -1
    private var stallTicks: Int = 0
    /// The known duration from track metadata (API-sourced, accurate).
    /// Separate from `duration` which may be overwritten by AVPlayer container duration.
    private var knownTrackDuration: Double = 0
    /// Guards against double-advance — a finishing track can trigger the end
    /// notification, duration detection, and stall detection all at once.
    private var finishedGeneration: Int = -1
    /// Bounded skip counter — prevents infinite recursion/crash when nothing is playable.
    private var consecutiveFailures: Int = 0
    private static let maxConsecutiveFailures = 40

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
        loadRecentlyPlayed()
        restoreLastPlayed()
    }

    private var activationRetryCount = 0
    private static let maxActivationRetries = 3

    private func activateSessionAndPlay(url: URL, generation: Int) {
        if sessionActivated {
            activationRetryCount = 0
            beginPlayback(url: url, generation: generation)
            return
        }
        let session = AVAudioSession.sharedInstance()
        session.activate(options: []) { [weak self] success, activationError in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                guard success else {
                    if self.activationRetryCount < Self.maxActivationRetries {
                        self.activationRetryCount += 1
                        let delay = UInt64(self.activationRetryCount) * 500_000_000
                        print("[Player] Activation retry \(self.activationRetryCount)/\(Self.maxActivationRetries)")
                        try? await Task.sleep(nanoseconds: delay)
                        guard self.playbackGeneration == generation else { return }
                        self.activateSessionAndPlay(url: url, generation: generation)
                    } else {
                        self.activationRetryCount = 0
                        self.error = "Audio activation failed: \(activationError?.localizedDescription ?? "unknown")"
                        self.isPlaying = false
                    }
                    return
                }
                self.activationRetryCount = 0
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
        consecutiveFailures = 0
        buildQueue(startingAt: index)
        guard !playQueue.isEmpty else {
            error = "No downloaded tracks in \(playlist.title)"
            stopPlayback()
            return
        }
        currentIndex = playQueue[queuePosition]
        playTrack(at: currentIndex)
    }

    /// Shuffle every downloaded track across ALL albums/playlists and play them in
    /// random order. Loops forever (repeat all) so it keeps going through everything.
    func playAllShuffled() {
        // Gather every available track across all playlists, deduped by videoId
        var seen = Set<String>()
        var tracks: [Track] = []
        for pl in WatchFileReceiver.shared.availablePlaylists {
            for t in pl.tracks where seen.insert(t.videoId).inserted {
                tracks.append(t)
            }
        }
        guard !tracks.isEmpty else {
            error = "No downloaded tracks"
            return
        }

        let synthetic = Playlist(id: "__all_songs__", title: "Shuffle All", thumbnailURL: nil, tracks: tracks)
        isShuffled = true
        repeatMode = .all
        currentPlaylist = synthetic
        consecutiveFailures = 0
        buildQueue(startingAt: Int.random(in: 0..<tracks.count))
        guard !playQueue.isEmpty else { stopPlayback(); return }
        haptic(.start)
        currentIndex = playQueue[queuePosition]
        playTrack(at: currentIndex)
    }

    func play() {
        guard player != nil else {
            // Player was torn down — re-initialize if we have a current track
            if let track = currentTrack,
               let url = WatchFileReceiver.shared.audioURL(for: track.videoId) {
                knownTrackDuration = track.durationSeconds > 0 ? Double(track.durationSeconds) : 0
                if duration <= 0 { duration = knownTrackDuration }
                lastObservedTime = -1
                stallTicks = 0
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
        haptic(.click)
        guard currentPlaylist != nil else { return }
        // Rebuild around the current track — buildQueue filters to available tracks
        // and keeps the current song at the front, so shuffle never gets "stuck".
        buildQueue(startingAt: currentIndex)
    }

    func toggleRepeat() {
        repeatMode = repeatMode.next
        haptic(.click)
    }

    // MARK: - Up Next

    var upNextTracks: [Track] {
        guard let playlist = currentPlaylist, !playQueue.isEmpty else { return [] }
        let remaining = playQueue.dropFirst(queuePosition + 1)
        return remaining.prefix(20).compactMap { idx -> Track? in
            guard idx >= 0, idx < playlist.tracks.count else { return nil }
            return playlist.tracks[idx]
        }
    }

    // MARK: - Sleep Timer

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let target = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerTarget = target
        sleepTimerRemaining = TimeInterval(minutes * 60)
        haptic(.start)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let target = self.sleepTimerTarget else { return }
                let remaining = target.timeIntervalSinceNow
                if remaining <= 0 {
                    self.cancelSleepTimer()
                    self.pause()
                    self.haptic(.stop)
                } else {
                    self.sleepTimerRemaining = remaining
                }
            }
        }
    }

    /// Sleep at end of current track
    func startSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepTimerRemaining = -1 // sentinel: end-of-track mode
        haptic(.start)
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemaining = nil
        sleepTimerTarget = nil
    }

    /// Re-sync timer on app wake — recalculates remaining from absolute target
    func refreshSleepTimer() {
        guard let target = sleepTimerTarget else { return }
        let remaining = target.timeIntervalSinceNow
        if remaining <= 0 {
            cancelSleepTimer()
            pause()
            haptic(.stop)
        } else {
            sleepTimerRemaining = remaining
        }
    }

    var isSleepTimerEndOfTrack: Bool { sleepTimerRemaining == -1 }

    // MARK: - Recently Played

    func loadRecentlyPlayed() {
        guard let data = UserDefaults.standard.data(forKey: "recentlyPlayed"),
              let decoded = try? JSONDecoder().decode([RecentPlay].self, from: data) else { return }
        recentlyPlayed = decoded
    }

    private func recordPlay(_ track: Track, playlist: Playlist) {
        recentlyPlayed.removeAll { $0.trackVideoId == track.videoId }
        let entry = RecentPlay(track: track, playlistId: playlist.id, playlistTitle: playlist.title, date: Date())
        recentlyPlayed.insert(entry, at: 0)
        if recentlyPlayed.count > Self.maxRecentPlays {
            recentlyPlayed = Array(recentlyPlayed.prefix(Self.maxRecentPlays))
        }
        if let data = try? JSONEncoder().encode(recentlyPlayed) {
            UserDefaults.standard.set(data, forKey: "recentlyPlayed")
        }
    }

    // MARK: - Haptics

    private func haptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    // MARK: - Private

    /// Indices of tracks in `playlist` whose audio file is actually on disk.
    /// Building the queue from these means shuffle/next never land on a missing
    /// (e.g. old-version) download.
    private func availableIndices(in playlist: Playlist) -> [Int] {
        playlist.tracks.indices.filter {
            WatchFileReceiver.shared.isAvailable(playlist.tracks[$0].videoId)
        }
    }

    private func buildQueue(startingAt index: Int) {
        guard let playlist = currentPlaylist else {
            playQueue = []; queuePosition = 0; return
        }
        let avail = availableIndices(in: playlist)
        guard !avail.isEmpty else {
            playQueue = []; queuePosition = 0; return
        }
        // Start on a track that actually has a file
        let start = avail.contains(index) ? index : avail[0]
        if isShuffled {
            var rest = avail.filter { $0 != start }
            rest.shuffle()
            playQueue = [start] + rest
            queuePosition = 0
        } else {
            playQueue = avail
            queuePosition = avail.firstIndex(of: start) ?? 0
        }
    }

    private func advanceQueue(forward: Bool) {
        guard let playlist = currentPlaylist else { return }
        guard !playQueue.isEmpty else { playNextPlaylist(); return }

        if forward {
            let next = queuePosition + 1
            if next < playQueue.count {
                queuePosition = next
            } else if repeatMode == .all {
                // Restart the same playlist — reshuffle if shuffled
                let restart = isShuffled ? (availableIndices(in: playlist).randomElement() ?? playQueue[0]) : playQueue[0]
                buildQueue(startingAt: restart)
                guard !playQueue.isEmpty else { playNextPlaylist(); return }
            } else {
                // End of queue in .none mode — move to next album/playlist
                playNextPlaylist()
                return
            }
        } else {
            let prev = queuePosition - 1
            if prev >= 0 {
                queuePosition = prev
            } else {
                return // already at first track
            }
        }

        guard queuePosition >= 0, queuePosition < playQueue.count else {
            playNextPlaylist(); return
        }
        currentIndex = playQueue[queuePosition]
        playTrack(at: currentIndex)
    }

    private func playTrack(at index: Int) {
        guard let playlist = currentPlaylist,
              index >= 0, index < playlist.tracks.count else { return }

        let track = playlist.tracks[index]
        guard let url = WatchFileReceiver.shared.audioURL(for: track.videoId) else {
            handleUnplayable(track: track, reason: "not downloaded")
            return
        }

        // Verify file is not empty/corrupt
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard fileSize > 1000 else {
            handleUnplayable(track: track, reason: "file corrupt")
            return
        }

        tearDownPlayer()

        playbackGeneration += 1
        let gen = playbackGeneration

        currentIndex = index
        currentTrack = track
        error = nil
        knownTrackDuration = track.durationSeconds > 0 ? Double(track.durationSeconds) : 0
        duration = knownTrackDuration
        currentTime = 0
        lastObservedTime = -1
        stallTicks = 0

        // Haptic + toast on track change
        haptic(.click)
        trackChangeToast = track
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.trackChangeToast?.videoId == track.videoId {
                self.trackChangeToast = nil
            }
        }

        // Record play
        if let playlist = currentPlaylist {
            recordPlay(track, playlist: playlist)
        }

        // Update Now Playing immediately so it shows even before audio starts
        updateNowPlaying()

        activateSessionAndPlay(url: url, generation: gen)
    }

    /// Called when a track can't be played. Bounded so it never infinitely
    /// recurses or crashes when many/all tracks are missing.
    private func handleUnplayable(track: Track, reason: String) {
        consecutiveFailures += 1
        print("[Player] Skip \(track.title): \(reason) (\(consecutiveFailures)/\(Self.maxConsecutiveFailures))")
        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            consecutiveFailures = 0
            error = "No playable tracks available"
            stopPlayback()
            return
        }
        advanceQueue(forward: true)
    }

    private func stopPlayback() {
        tearDownPlayer()
        isPlaying = false
        currentTime = 0
        updateNowPlaying()
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

        let capturedGen = generation

        // Block-based end observer that captures THIS item's generation, so the end
        // notification, duration detection, and stall detection all dedupe against the
        // same generation — no more double-advance / skipped tracks.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished(generation: capturedGen) }
        }
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
                    self.consecutiveFailures = 0 // successful start resets the skip guard
                    // Prefer Track metadata duration; fall back to AVPlayer if unknown.
                    // Old-version downloads have durationSeconds=0 — heal them by reading
                    // the asset's real duration and persisting it so the UI + end detection work.
                    if self.knownTrackDuration <= 0, !dur.isNaN, dur > 0 {
                        self.duration = dur
                        if let vid = self.currentTrack?.videoId {
                            WatchFileReceiver.shared.updateTrackDuration(videoId: vid, duration: Int(dur.rounded()))
                        }
                    }
                    self.player?.play()
                    self.player?.volume = self.currentVolume
                    self.isPlaying = true
                    self.updateNowPlaying()
                    self.saveLastPlayed()
                    // Retry artwork after short delay (thumbnail may arrive after audio)
                    let artworkGen = capturedGen
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard self.playbackGeneration == artworkGen else { return }
                        self.updateNowPlaying()
                    }
                case .failed:
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    let msg = errMsg ?? "Playback failed"
                    let failed = self.currentTrack
                    print("[Player] \u{2717} \(failed?.title ?? "?"): \(msg)")
                    // The file is corrupt — delete it so it stops crashing playback and
                    // gets re-synced from the phone on the next Verify & Re-sync.
                    if let vid = failed?.videoId, !vid.isEmpty {
                        WatchFileReceiver.shared.deleteCorruptAudioFile(videoId: vid)
                    }
                    // Auto-skip on failure, bounded to avoid infinite loops on bad catalogs
                    self.handleUnplayable(track: failed ?? Track(id: "", videoId: "", title: "?", artist: "", durationSeconds: 0), reason: "load failed")
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
                let t = time.seconds
                self.currentTime = t
                var needsNowPlayingUpdate = false

                // Only use AVPlayer duration if we have no Track metadata duration
                // Never overwrite known metadata duration — AVPlayer reports container
                // duration which may include minutes of silence padding
                if self.knownTrackDuration <= 0 && self.duration <= 0,
                   let d = self.playerItem?.duration.seconds, !d.isNaN, d > 0 {
                    self.duration = d
                    needsNowPlayingUpdate = true
                }

                // Duration-based end detection: only skip early when the container is
                // meaningfully LONGER than the real track duration (i.e. there's trailing
                // silence padding). If the container matches, let it play to the natural
                // end (the end notification handles it) — this avoids cutting songs off
                // early when metadata duration is slightly short.
                if self.isPlaying && self.knownTrackDuration > 0 && t >= self.knownTrackDuration - 0.3 {
                    let containerDur = self.playerItem?.duration.seconds ?? .nan
                    let hasPadding = !containerDur.isNaN && containerDur > self.knownTrackDuration + 2
                    if hasPadding {
                        print("[Player] Known duration \(String(format: "%.1f", self.knownTrackDuration))s reached (container \(String(format: "%.1f", containerDur))s has padding), advancing")
                        self.handleTrackFinished(generation: capturedGen)
                        return
                    }
                }

                // Stall detection: if time stops advancing while playing, audio ended
                // (fallback for tracks without known duration)
                if self.isPlaying && t > 1 {
                    if abs(t - self.lastObservedTime) < 0.05 {
                        self.stallTicks += 1
                        if self.stallTicks >= 3 { // 1.5 seconds stalled
                            print("[Player] Stall detected at \(String(format: "%.1f", t))s, advancing")
                            self.stallTicks = 0
                            self.handleTrackFinished(generation: capturedGen)
                            return
                        }
                    } else {
                        self.stallTicks = 0
                    }
                }
                self.lastObservedTime = t

                self.timeObserverTick += 1
                if needsNowPlayingUpdate || self.timeObserverTick % 2 == 0 {
                    self.updateNowPlaying()
                }
                if self.timeObserverTick % 20 == 0 { self.saveLastPlayed() }
            }
        }
    }

    private func tearDownPlayer() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        playerItem = nil
    }

    /// Handle a track finishing. `generation` is the generation of the item that
    /// finished — dedupes the three finish signals (end notification, duration
    /// detection, stall detection) so a track is only advanced once.
    private func handleTrackFinished(generation: Int) {
        // Only act on the currently-playing generation, and only once for it.
        guard generation == playbackGeneration else { return }
        guard finishedGeneration != generation else { return }
        finishedGeneration = generation

        // Sleep timer: end-of-track mode
        if isSleepTimerEndOfTrack {
            cancelSleepTimer()
            pause()
            haptic(.stop)
            return
        }

        switch repeatMode {
        case .one:
            // Replay same track (playTrack bumps generation so it can finish again)
            playTrack(at: currentIndex)
        case .all, .none:
            // advanceQueue handles end-of-queue: .all restarts, .none moves to next album
            advanceQueue(forward: true)
        }
    }

    private func playNextPlaylist() {
        let all = WatchFileReceiver.shared.availablePlaylists
        guard !all.isEmpty else { stopPlayback(); return }

        let currentId = currentPlaylist?.id
        let startIdx = all.firstIndex(where: { $0.id == currentId }) ?? -1

        // Walk forward looking for the next album/playlist that has playable tracks.
        for offset in 1...all.count {
            let idx = ((startIdx < 0 ? 0 : startIdx) + offset) % all.count
            let candidate = all[idx]

            if candidate.id == currentId {
                // Wrapped all the way back to the current playlist.
                if repeatMode == .all {
                    currentPlaylist = candidate
                    consecutiveFailures = 0
                    buildQueue(startingAt: 0)
                    if !playQueue.isEmpty {
                        currentIndex = playQueue[queuePosition]
                        playTrack(at: currentIndex)
                        return
                    }
                }
                break
            }

            if !availableIndices(in: candidate).isEmpty {
                currentPlaylist = candidate
                consecutiveFailures = 0
                buildQueue(startingAt: availableIndices(in: candidate).first ?? 0)
                if !playQueue.isEmpty {
                    currentIndex = playQueue[queuePosition]
                    playTrack(at: currentIndex)
                    return
                }
            }
        }
        // Nothing playable anywhere — stop cleanly.
        stopPlayback()
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
              let image = Self.downsampledImage(at: url, maxPixel: 300) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (track.videoId, artwork)
        return artwork
    }

    /// Decode a downsampled image with ImageIO — avoids holding a full-size bitmap
    /// in memory (important on the memory-constrained Watch).
    private static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
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
              savedIndex >= 0,
              savedIndex < playlist.tracks.count,
              playlist.tracks[savedIndex].videoId == trackVideoId else { return }

        currentPlaylist = playlist
        currentIndex = savedIndex
        let track = playlist.tracks[savedIndex]
        currentTrack = track
        buildQueue(startingAt: savedIndex)
        knownTrackDuration = track.durationSeconds > 0 ? Double(track.durationSeconds) : 0
        duration = knownTrackDuration
        currentTime = savedTime
    }
}
