import AVFoundation
import AppKit
import Combine
import Foundation
import MediaPlayer

@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngineDidEndCurrentTrack(_ engine: PlaybackEngine)
    func playbackEngine(_ engine: PlaybackEngine, didUpdatePosition position: Double, duration: Double)
    func playbackEngine(_ engine: PlaybackEngine, didTransitionTo state: PlaybackState)
    func playbackEngineDidRequestTogglePlayback(_ engine: PlaybackEngine)
    func playbackEngineDidRequestNextTrack(_ engine: PlaybackEngine)
    func playbackEngineDidRequestPreviousTrack(_ engine: PlaybackEngine)
    func playbackEngine(_ engine: PlaybackEngine, didRequestSeekTo position: Double)
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
    private var deferredBufferingTransitionTask: Task<Void, Never>?
    private var bufferingRetryTask: Task<Void, Never>?
    private var lastPlaybackProgressDate: Date?
    private var playbackPreparationID: Int = 0
    private var prebufferPreparationID: Int = 0
    private var seekID: Int = 0
    private var bufferingRetryCount = 0
    private var isPlaybackRequested = false
    private var loudnessGainCache: [String: Float] = [:]
    private var missingLoudnessAnalysisTrackIDs = Set<String>()
    private var _currentTrack: MediaTrack?
    private var prebufferedTrackID: String?
    private var prebufferedItem: AVPlayerItem?
    private var prebufferTask: Task<Void, Never>?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingInfoTrackID: String?
    private let bufferingTransitionDelayNanoseconds: UInt64 = 1_500_000_000
    private let bufferingRetryDelayNanoseconds: UInt64 = 8_000_000_000
    private let maximumBufferingRetryCount = 3
    private let prebufferRetryDelayNanoseconds: UInt64 = 2_000_000_000
    private let maximumPrebufferRetryCount = 3

    init(context: StoreContext) {
        self.context = context
        configureRemoteCommandCenter()
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
            cancelBufferingRetry()
            player.pause()
            transitionPlaybackState(to: .paused)
            refreshNowPlayingInfo()
        case .paused, .stopped:
            isPlaybackRequested = true
            player.play()
            synchronizePlaybackState(with: player.timeControlStatus)
            refreshNowPlayingInfo()
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
                self.refreshNowPlayingInfo()
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

    func setFallbackLoudnessGainDecibels(_ decibels: Int) {
        let clampedDecibels = PlaybackSettings.clampedFallbackLoudnessGain(decibels)
        guard context.settingsStore.settings.fallbackLoudnessGainDecibels != clampedDecibels else { return }
        context.settingsStore.settings.fallbackLoudnessGainDecibels = clampedDecibels
        logDebug("Fallback loudness gain set to \(clampedDecibels) dB")

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
        clearNowPlayingInfo()
    }

    func stopPlayback() {
        player?.pause()
        removeTimeObserver()
        playerItemEndObserver = nil
        playerItemStatusObserver = nil
        playerTimeControlStatusObserver = nil
        cancelDeferredBufferingTransition()
        cancelBufferingRetry()
        lastPlaybackProgressDate = nil
        bufferingRetryCount = 0
        player = nil
        clearPrebufferedTrack()
        refreshNowPlayingInfo()
    }

    func clearCaches() {
        loudnessGainCache.removeAll()
        missingLoudnessAnalysisTrackIDs.removeAll()
    }

    func prebufferNextTrack(_ track: MediaTrack?) {
        let preparationID = nextPrebufferPreparationID()
        prebufferTask?.cancel()

        guard let track, track.id != _currentTrack?.id else {
            prebufferedTrackID = nil
            prebufferedItem = nil
            return
        }

        if prebufferedTrackID == track.id, prebufferedItem != nil {
            return
        }

        prebufferedTrackID = nil
        prebufferedItem = nil
        prebufferTask = Task {
            for attempt in 1...maximumPrebufferRetryCount {
                let asset = AVURLAsset(url: track.streamURL)
                do {
                    _ = try await asset.load(.isPlayable)
                    guard !Task.isCancelled, preparationID == self.prebufferPreparationID else { return }
                    self.prebufferedTrackID = track.id
                    self.prebufferedItem = AVPlayerItem(asset: asset)
                    self.logDebug("Prebuffered next track \(track.title)")
                    return
                } catch {
                    guard !Task.isCancelled, preparationID == self.prebufferPreparationID else { return }
                    self.prebufferedTrackID = nil
                    self.prebufferedItem = nil
                    self.logDebug("Prebuffer next track failed for \(track.title) (attempt \(attempt)/\(maximumPrebufferRetryCount)): \(error.localizedDescription)")

                    guard attempt < maximumPrebufferRetryCount else { return }
                    try? await Task.sleep(nanoseconds: prebufferRetryDelayNanoseconds)
                    guard !Task.isCancelled, preparationID == self.prebufferPreparationID else { return }
                }
            }
        }
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
        nowPlayingInfoTrackID = track.id
        nowPlayingArtwork = nil
        refreshNowPlayingInfo()
        loadNowPlayingArtwork(from: track)
    }

    private func preparePlayer(for track: MediaTrack) async {
        let preparationID = nextPlaybackPreparationID()
        _currentTrack = track

        let volume = await resolvePlaybackVolume(for: track)
        guard preparationID == playbackPreparationID else { return }

        invalidatePendingSeek()
        lastPlaybackProgressDate = nil
        bufferingRetryCount = 0
        cancelBufferingRetry()
        context.timelineTracker?.beginTracking(track)
        context.libraryStore?.refreshRelatedAlbums(for: track)
        let item = preparedPlayerItem(for: track)
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
            return fallbackPlaybackVolume(for: track, reason: "No loudness analysis available")
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
        if context.mediaService is LocalService {
            return false
        }

        return track.ratingKey != nil || !track.id.isEmpty
    }

    private func fetchLoudnessGain(for loudnessID: String, track: MediaTrack) async throws -> Float? {
        try await context.mediaService.fetchLoudnessGain(ratingKey: loudnessID)
    }

    private func loudnessCacheKey(for loudnessID: String) -> String {
        "\(String(describing: type(of: context.mediaService))):\(loudnessID)"
    }

    private func fallbackPlaybackVolume(for track: MediaTrack, reason: String) -> Float {
        let fallbackLoudnessGain = Float(context.settingsStore.settings.fallbackLoudnessGainDecibels)
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

    private func preparedPlayerItem(for track: MediaTrack) -> AVPlayerItem {
        guard prebufferedTrackID == track.id,
              let prebufferedItem else {
            logDebug("No prebuffered item for \(track.title); starting stream directly")
            return AVPlayerItem(url: track.streamURL)
        }

        self.prebufferedTrackID = nil
        self.prebufferedItem = nil
        logDebug("Using prebuffered item for \(track.title)")
        return prebufferedItem
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
                            self.scheduleBufferingRetryIfNeeded()
                        }
                    case .failed:
                        self.transitionPlaybackState(to: self.isPlaybackRequested ? .buffering : .paused)
                        if self.isPlaybackRequested {
                            self.scheduleBufferingRetryIfNeeded()
                        }
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
                    if seconds > self.playbackPosition + 0.1 {
                        self.lastPlaybackProgressDate = Date()
                        if self.isPlaybackRequested {
                            self.cancelDeferredBufferingTransition()
                            self.cancelBufferingRetry()
                            self.bufferingRetryCount = 0
                            self.transitionPlaybackState(to: .playing)
                        }
                    }
                    self.playbackPosition = max(0, seconds)
                }

                if let duration = player.currentItem?.duration.seconds,
                   duration.isFinite,
                   duration > 0,
                   self.playbackDuration != duration {
                    self.playbackDuration = duration
                }

                self.refreshNowPlayingInfo()
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
        refreshNowPlayingInfo()
    }

    private func removeTimeObserver() {
        guard let player, let timeObserverToken else { return }
        player.removeTimeObserver(timeObserverToken)
        self.timeObserverToken = nil
    }

    private func synchronizePlaybackState(with timeControlStatus: AVPlayer.TimeControlStatus) {
        switch timeControlStatus {
        case .paused:
            cancelDeferredBufferingTransition()
            if isPlaybackRequested, player?.currentItem?.status == .readyToPlay {
                transitionPlaybackState(to: .playing)
                scheduleBufferingRetryIfNeeded()
            } else {
                if !isPlaybackRequested {
                    cancelBufferingRetry()
                }
                transitionPlaybackState(to: isPlaybackRequested ? .buffering : .paused)
            }
        case .waitingToPlayAtSpecifiedRate:
            if isPlaybackRequested {
                scheduleDeferredBufferingTransition()
                scheduleBufferingRetryIfNeeded()
            } else {
                cancelDeferredBufferingTransition()
                cancelBufferingRetry()
                transitionPlaybackState(to: .paused)
            }
        case .playing:
            cancelDeferredBufferingTransition()
            cancelBufferingRetry()
            transitionPlaybackState(to: isPlaybackRequested ? .playing : .paused)
        @unknown default:
            if isPlaybackRequested {
                scheduleDeferredBufferingTransition()
                scheduleBufferingRetryIfNeeded()
            } else {
                cancelDeferredBufferingTransition()
                cancelBufferingRetry()
                transitionPlaybackState(to: .paused)
            }
        }
    }

    private func scheduleDeferredBufferingTransition() {
        guard playbackState == .playing else {
            cancelDeferredBufferingTransition()
            transitionPlaybackState(to: .buffering)
            return
        }

        guard deferredBufferingTransitionTask == nil else { return }

        let delay = bufferingTransitionDelayNanoseconds
        deferredBufferingTransitionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.deferredBufferingTransitionTask = nil
                guard self.isPlaybackRequested,
                      self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                guard !self.hasRecentPlaybackProgress else { return }
                self.transitionPlaybackState(to: .buffering)
            }
        }
    }

    private var hasRecentPlaybackProgress: Bool {
        guard let lastPlaybackProgressDate else { return false }
        return Date().timeIntervalSince(lastPlaybackProgressDate) < 2
    }

    private func cancelDeferredBufferingTransition() {
        deferredBufferingTransitionTask?.cancel()
        deferredBufferingTransitionTask = nil
    }

    private func scheduleBufferingRetryIfNeeded() {
        guard bufferingRetryTask == nil,
              isPlaybackRequested,
              let track = _currentTrack,
              bufferingRetryCount < maximumBufferingRetryCount else { return }

        let preparationID = playbackPreparationID
        let trackID = track.id
        let trackTitle = track.title
        let streamURL = track.streamURL
        let delay = bufferingRetryDelayNanoseconds

        bufferingRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.bufferingRetryTask = nil
                guard self.shouldRetryBuffering(trackID: trackID, preparationID: preparationID) else { return }
                self.retryBufferingPlayback(trackID: trackID, title: trackTitle, streamURL: streamURL)
            }
        }
    }

    private func shouldRetryBuffering(trackID: String, preparationID: Int) -> Bool {
        guard isPlaybackRequested,
              playbackPreparationID == preparationID,
              _currentTrack?.id == trackID,
              !hasRecentPlaybackProgress,
              bufferingRetryCount < maximumBufferingRetryCount else { return false }

        if player?.currentItem?.status == .failed {
            return true
        }

        return player?.timeControlStatus == .waitingToPlayAtSpecifiedRate || playbackState == .buffering
    }

    private func retryBufferingPlayback(trackID: String, title: String, streamURL: URL) {
        bufferingRetryCount += 1
        logDebug("Retrying playback for \(title) after buffering stalled (attempt \(bufferingRetryCount)/\(maximumBufferingRetryCount))")

        if prebufferedTrackID == trackID {
            prebufferedTrackID = nil
            prebufferedItem = nil
        }

        let resumeTime = playbackPosition
        let item = AVPlayerItem(url: streamURL)
        observePlaybackEnd(for: item)
        observePlayerItemStatus(for: item)

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
            observePlaybackTime()
            observePlayerTimeControlStatus()
        }

        updatePlaybackTiming(from: item)
        if resumeTime > 1 {
            playbackPosition = resumeTime
            let targetTime = CMTime(seconds: resumeTime, preferredTimescale: 600)
            player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player?.play()
        transitionPlaybackState(to: .buffering)
        synchronizePlaybackState(with: player?.timeControlStatus ?? .waitingToPlayAtSpecifiedRate)
        scheduleBufferingRetryIfNeeded()
    }

    private func cancelBufferingRetry() {
        bufferingRetryTask?.cancel()
        bufferingRetryTask = nil
    }

    private func transitionPlaybackState(to newState: PlaybackState) {
        guard playbackState != newState else { return }
        playbackState = newState
        refreshNowPlayingInfo()
        delegate?.playbackEngine(self, didTransitionTo: newState)
    }

    private func configureRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        remoteCommandTargets = [
            (commandCenter.playCommand, commandCenter.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.playbackState != .playing else { return }
                    self.delegate?.playbackEngineDidRequestTogglePlayback(self)
                }
                return .success
            }),
            (commandCenter.pauseCommand, commandCenter.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.playbackState == .playing || self.playbackState == .buffering else { return }
                    self.delegate?.playbackEngineDidRequestTogglePlayback(self)
                }
                return .success
            }),
            (commandCenter.togglePlayPauseCommand, commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.delegate?.playbackEngineDidRequestTogglePlayback(self)
                }
                return .success
            }),
            (commandCenter.nextTrackCommand, commandCenter.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.delegate?.playbackEngineDidRequestNextTrack(self)
                }
                return .success
            }),
            (commandCenter.previousTrackCommand, commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.delegate?.playbackEngineDidRequestPreviousTrack(self)
                }
                return .success
            }),
            (commandCenter.changePlaybackPositionCommand, commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }

                Task { @MainActor in
                    guard let self else { return }
                    self.delegate?.playbackEngine(self, didRequestSeekTo: event.positionTime)
                }
                return .success
            }),
        ]
    }

    private func refreshNowPlayingInfo() {
        guard nowPlaying != .placeholder else {
            clearNowPlayingInfo()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.trackName,
            MPMediaItemPropertyAlbumTitle: nowPlaying.albumName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackPosition,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]

        if let artist = nowPlaying.trackArtist ?? nowPlaying.albumArtist {
            info[MPMediaItemPropertyArtist] = artist
        }

        if playbackDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = playbackDuration
        }

        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }

        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = nowPlayingPlaybackState
    }

    private func clearNowPlayingInfo() {
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtwork = nil
        nowPlayingInfoTrackID = nil
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingInfoCenter.playbackState = .stopped
    }

    private var nowPlayingPlaybackState: MPNowPlayingPlaybackState {
        switch playbackState {
        case .playing, .buffering:
            return .playing
        case .paused:
            return .paused
        case .stopped:
            return .stopped
        }
    }

    private func loadNowPlayingArtwork(from track: MediaTrack) {
        nowPlayingArtworkTask?.cancel()

        guard let artworkURL = track.artworkURL else { return }

        let trackID = track.id
        nowPlayingArtworkTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let data: Data
                if artworkURL.isFileURL {
                    data = try Data(contentsOf: artworkURL)
                } else {
                    let (remoteData, _) = try await URLSession.shared.data(from: artworkURL)
                    data = remoteData
                }

                guard !Task.isCancelled,
                      let image = NSImage(data: data) else { return }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run {
                    guard let self,
                          self.nowPlayingInfoTrackID == trackID,
                          !Task.isCancelled else { return }
                    self.nowPlayingArtwork = artwork
                    self.refreshNowPlayingInfo()
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.nowPlayingInfoTrackID == trackID else { return }
                    self.logDebug("Now playing artwork load failed for \(track.title): \(error.localizedDescription)")
                }
            }
        }
    }

    private func invalidatePendingSeek() {
        seekID += 1
        pendingSeekProgress = nil
    }

    private func nextPlaybackPreparationID() -> Int {
        playbackPreparationID += 1
        return playbackPreparationID
    }

    private func nextPrebufferPreparationID() -> Int {
        prebufferPreparationID += 1
        return prebufferPreparationID
    }

    private func nextSeekID() -> Int {
        seekID += 1
        return seekID
    }

    private func clearPrebufferedTrack() {
        prebufferTask?.cancel()
        prebufferTask = nil
        prebufferedTrackID = nil
        prebufferedItem = nil
        _ = nextPrebufferPreparationID()
    }

    private func logDebug(_ message: String) {
        PlexLog.debug(message, category: .playback)
    }
}
