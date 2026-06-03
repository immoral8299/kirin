import AVFoundation
import Combine
import Foundation

@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngineDidEndCurrentTrack(_ engine: PlaybackEngine)
    func playbackEngine(_ engine: PlaybackEngine, didUpdatePosition position: Double, duration: Double)
    func playbackEngine(_ engine: PlaybackEngine, didTransitionTo state: PlaybackState)
}

@MainActor
final class PlaybackEngine: ObservableObject {
    @Published var playbackState: PlaybackState = .paused
    @Published var nowPlaying: TrackMetadata = .placeholder
    @Published var playbackPosition: Double = 0
    @Published var playbackDuration: Double = 0
    @Published var pendingSeekProgress: Double?

    weak var delegate: PlaybackEngineDelegate?

    private let context: StoreContext
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playerItemEndObserver: AnyCancellable?
    private var playerItemStatusObserver: AnyCancellable?
    private var playerTimeControlStatusObserver: AnyCancellable?
    private var playbackPreparationID: Int = 0
    private var seekID: Int = 0
    private var isPlaybackRequested = false
    private var loudnessGainCache: [String: Float] = [:]
    private var missingLoudnessAnalysisTrackIDs = Set<String>()
    private var _currentTrack: MediaTrack?
    private let fallbackLoudnessGain: Float = -6

    init(context: StoreContext) {
        self.context = context
    }

    var currentTrack: MediaTrack? { _currentTrack }

    var playbackProgress: Double {
        if let pendingSeekProgress {
            return pendingSeekProgress
        }
        guard playbackDuration > 0 else { return 0 }
        return min(max(playbackPosition / playbackDuration, 0), 1)
    }

    var isLoudnessLevelingEnabled: Bool {
        context.settingsStore.settings.loudnessLevelingEnabled
    }

    func togglePlayback() {
        guard let player else { return }

        switch playbackState {
        case .playing, .buffering:
            isPlaybackRequested = false
            player.pause()
            transitionPlaybackState(to: .paused)
        case .paused, .stopped:
            isPlaybackRequested = true
            player.play()
            synchronizePlaybackState(with: player.timeControlStatus)
        }
    }

    func seekToProgress(_ progress: Double) {
        guard let player, playbackDuration > 0 else { return }

        let clampedProgress = min(max(progress, 0), 1)
        let targetTime = CMTime(seconds: playbackDuration * clampedProgress, preferredTimescale: 600)
        let currentSeekID = nextSeekID()
        pendingSeekProgress = clampedProgress
        playbackPosition = min(max(targetTime.seconds, 0), playbackDuration)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, currentSeekID == self.seekID else { return }
                self.playbackPosition = min(max(targetTime.seconds, 0), self.playbackDuration)
                self.pendingSeekProgress = nil
            }
        }
    }

    func setLoudnessLevelingEnabled(_ isEnabled: Bool) {
        guard context.settingsStore.settings.loudnessLevelingEnabled != isEnabled else { return }
        context.settingsStore.settings.loudnessLevelingEnabled = isEnabled
        logDebug(isEnabled ? "Loudness leveling enabled" : "Loudness leveling disabled")

        guard let currentTrack = _currentTrack else { return }
        Task {
            await applyPlaybackVolume(for: currentTrack)
        }
    }

    func playCurrentTrack() async {
        guard let track = _currentTrack else { return }
        updateNowPlaying(from: track)
        isPlaybackRequested = true
        playbackState = .buffering
        await preparePlayer(for: track)
        guard _currentTrack?.id == track.id else { return }
        player?.play()
        synchronizePlaybackState(with: player?.timeControlStatus ?? .waitingToPlayAtSpecifiedRate)
    }

    func play(track: MediaTrack) async {
        _currentTrack = track
        await playCurrentTrack()
    }

    func preparePreviewTrack(_ track: MediaTrack) {
        updateNowPlaying(from: track)
        Task {
            await preparePlayer(for: track)
            isPlaybackRequested = false
            playbackState = .paused
        }
    }

    func resetForNewTrack() {
        stopPlayback()
        _currentTrack = nil
        nowPlaying = .placeholder
        isPlaybackRequested = false
        playbackState = .stopped
        playbackPosition = 0
        playbackDuration = 0
    }

    func stopPlayback() {
        player?.pause()
        removeTimeObserver()
        playerItemEndObserver = nil
        playerItemStatusObserver = nil
        player = nil
    }

    func clearCaches() {
        loudnessGainCache.removeAll()
        missingLoudnessAnalysisTrackIDs.removeAll()
    }

    // MARK: - Private

    func updateNowPlaying(from track: MediaTrack) {
        nowPlaying = TrackMetadata(
            trackName: track.title,
            trackArtist: track.trackArtist,
            albumArtist: track.albumArtist,
            albumName: track.albumName,
            artworkURL: track.artworkURL,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber
        )
    }

    private func preparePlayer(for track: MediaTrack) async {
        let preparationID = nextPlaybackPreparationID()
        _currentTrack = track

        let volume = await resolvePlaybackVolume(for: track)
        guard preparationID == playbackPreparationID else { return }

        invalidatePendingSeek()
        context.timelineTracker?.beginTracking(track)
        context.libraryStore?.refreshRelatedAlbums(for: track)
        let item = AVPlayerItem(url: track.streamURL)
        observePlaybackEnd(for: item)
        observePlayerItemStatus(for: item)

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
        }

        player?.volume = volume
        observePlaybackTime()
        observePlayerTimeControlStatus()
        updatePlaybackTiming(from: item)
    }

    private func applyPlaybackVolume(for track: MediaTrack) async {
        let volume = await resolvePlaybackVolume(for: track)
        guard _currentTrack?.id == track.id else { return }
        player?.volume = volume
    }

    private func resolvePlaybackVolume(for track: MediaTrack) async -> Float {
        guard context.settingsStore.settings.loudnessLevelingEnabled else {
            logDebug("Loudness leveling disabled for \(track.title)")
            return 1.0
        }

        logDebug("Loudness leveling enabled for \(track.title)")

        guard canResolveLoudnessGain(for: track) else {
            return 1.0
        }

        let loudnessID = track.ratingKey ?? track.id
        let cacheKey = loudnessCacheKey(for: loudnessID)

        if let cachedGain = loudnessGainCache[cacheKey] {
            let volume = volumeScalar(for: cachedGain)
            logDebug("Applied cached loudness gain \(formatted(decibels: cachedGain)) dB to \(track.title)")
            return volume
        }

        if missingLoudnessAnalysisTrackIDs.contains(cacheKey) {
            return fallbackPlaybackVolume(for: track, reason: "No loudness analysis found")
        }

        do {
            guard let gain = try await fetchLoudnessGain(for: loudnessID, track: track) else {
                missingLoudnessAnalysisTrackIDs.insert(cacheKey)
                return fallbackPlaybackVolume(for: track, reason: "No loudness analysis found")
            }

            loudnessGainCache[cacheKey] = gain
            let volume = volumeScalar(for: gain)

            if volume < 1.0 {
                logDebug("Applied loudness gain \(formatted(decibels: gain)) dB to \(track.title)")
            } else {
                logDebug("Found loudness gain \(formatted(decibels: gain)) dB for \(track.title), using unity volume")
            }

            return volume
        } catch {
            missingLoudnessAnalysisTrackIDs.insert(cacheKey)
            return fallbackPlaybackVolume(for: track, reason: "Skipped loudness lookup: \(error.localizedDescription)")
        }
    }

    private func canResolveLoudnessGain(for track: MediaTrack) -> Bool {
        if let plexService = context.mediaService as? PlexService {
            guard context.libraryStore?.selectedPlexServer != nil,
                  context.libraryStore?.selectedPlexLibrary != nil,
                  plexService.authService.authToken != nil else {
                logDebug("Skipping Plex loudness leveling for \(track.title): missing active Plex library")
                return false
            }
            return true
        }

        if context.mediaService is NavidromeService {
            return true
        }

        logDebug("Skipping loudness leveling for \(track.title): unsupported media service")
        return false
    }

    private func fetchLoudnessGain(for loudnessID: String, track: MediaTrack) async throws -> Float? {
        if let plexService = context.mediaService as? PlexService {
            guard let server = context.libraryStore?.selectedPlexServer,
                  context.libraryStore?.selectedPlexLibrary != nil,
                  let userToken = plexService.authService.authToken else {
                logDebug("Skipping Plex loudness leveling for \(track.title): missing active Plex library")
                return nil
            }

            return try await plexService.fetchLoudnessGain(server: server, ratingKey: loudnessID, userToken: userToken)
        }

        if context.mediaService is NavidromeService {
            return try await context.mediaService.fetchLoudnessGain(ratingKey: loudnessID)
        }

        logDebug("Skipping loudness leveling for \(track.title): unsupported media service")
        return nil
    }

    private func loudnessCacheKey(for loudnessID: String) -> String {
        "\(String(describing: type(of: context.mediaService))):\(loudnessID)"
    }

    private func fallbackPlaybackVolume(for track: MediaTrack, reason: String) -> Float {
        let volume = volumeScalar(for: fallbackLoudnessGain)
        logDebug("\(reason) for \(track.title); applying fallback \(formatted(decibels: fallbackLoudnessGain)) dB")
        return volume
    }

    private func volumeScalar(for gainInDecibels: Float) -> Float {
        guard gainInDecibels < 0 else { return 1.0 }
        return max(0.05, min(1.0, pow(10, gainInDecibels / 20)))
    }

    private func formatted(decibels: Float) -> String {
        String(format: "%.2f", decibels)
    }

    private func handlePlaybackEnded() {
        delegate?.playbackEngineDidEndCurrentTrack(self)
    }

    private func observePlaybackEnd(for item: AVPlayerItem) {
        playerItemEndObserver = nil
        playerItemEndObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackEnded()
                }
            }
    }

    private func observePlayerItemStatus(for item: AVPlayerItem) {
        playerItemStatusObserver = item.publisher(for: \.status)
            .sink { [weak self] status in
                Task { @MainActor in
                    guard let self, self.player?.currentItem === item else { return }
                    switch status {
                    case .readyToPlay:
                        self.updatePlaybackTiming(from: item)
                        if self.isPlaybackRequested {
                            self.transitionPlaybackState(to: .playing)
                        }
                    case .failed:
                        self.transitionPlaybackState(to: .paused)
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
    }

    private func observePlaybackTime() {
        guard let player, timeObserverToken == nil else { return }

        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let seconds = time.seconds
                if seconds.isFinite, self.pendingSeekProgress == nil {
                    self.playbackPosition = max(0, seconds)
                }

                if let duration = player.currentItem?.duration.seconds,
                   duration.isFinite,
                   duration > 0,
                   self.playbackDuration != duration {
                    self.playbackDuration = duration
                }

                self.delegate?.playbackEngine(self, didUpdatePosition: self.playbackPosition, duration: self.playbackDuration)
            }
        }
    }

    private func observePlayerTimeControlStatus() {
        guard let player, playerTimeControlStatusObserver == nil else { return }

        playerTimeControlStatusObserver = player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                Task { @MainActor in
                    self?.synchronizePlaybackState(with: status)
                }
            }
    }

    private func updatePlaybackTiming(from item: AVPlayerItem) {
        playbackPosition = 0

        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            playbackDuration = duration
        } else if let durationMilliseconds = _currentTrack?.durationMilliseconds {
            playbackDuration = Double(durationMilliseconds) / 1_000
        } else {
            playbackDuration = 0
        }
    }

    private func removeTimeObserver() {
        guard let player, let timeObserverToken else { return }
        player.removeTimeObserver(timeObserverToken)
        self.timeObserverToken = nil
    }

    private func synchronizePlaybackState(with timeControlStatus: AVPlayer.TimeControlStatus) {
        switch timeControlStatus {
        case .paused:
            if isPlaybackRequested, player?.currentItem?.status == .readyToPlay {
                transitionPlaybackState(to: .playing)
            } else {
                transitionPlaybackState(to: isPlaybackRequested ? .buffering : .paused)
            }
        case .waitingToPlayAtSpecifiedRate:
            transitionPlaybackState(to: isPlaybackRequested ? .buffering : .paused)
        case .playing:
            transitionPlaybackState(to: isPlaybackRequested ? .playing : .paused)
        @unknown default:
            transitionPlaybackState(to: isPlaybackRequested ? .buffering : .paused)
        }
    }

    private func transitionPlaybackState(to newState: PlaybackState) {
        guard playbackState != newState else { return }
        playbackState = newState
        delegate?.playbackEngine(self, didTransitionTo: newState)
    }

    private func invalidatePendingSeek() {
        seekID += 1
        pendingSeekProgress = nil
    }

    private func nextPlaybackPreparationID() -> Int {
        playbackPreparationID += 1
        return playbackPreparationID
    }

    private func nextSeekID() -> Int {
        seekID += 1
        return seekID
    }

    private func logDebug(_ message: String) {
        PlexLog.debug(message, category: .playback)
    }
}
