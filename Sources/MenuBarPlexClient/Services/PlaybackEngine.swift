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
    @Published var canSeek = false

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
    private var currentPlaybackToken = UUID()
    private var resolvedPlaybackDuration: ResolvedPlaybackDuration?
    private var pendingDeferredSeek: PendingDeferredSeek?
    private var hasCompletedCurrentTrack = false
    private var logicalPlaybackAnchor: LogicalPlaybackAnchor?
    private var currentTransportStartSeconds: Double?
    private var loudnessGainCache: [String: Float] = [:]
    private var missingLoudnessAnalysisTrackIDs = Set<String>()
    private var _currentTrack: MediaTrack?
    private var prebufferedTrackID: String?
    private var prebufferedItem: AVPlayerItem?
    private var prebufferTask: Task<Void, Never>?
    private var durationResolutionTask: Task<Void, Never>?
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
        let clampedProgress = min(max(progress, 0), 1)

        guard let player,
              let currentResolvedDuration = resolvedPlaybackDuration,
              currentResolvedDuration.seconds > 0 else {
            logDebug(
                "Ignored seek for \(nowPlaying.trackName): canSeek=\(canSeek), " +
                    "duration \(formattedTimestamp(playbackDuration)), " +
                    "durationSource \(resolvedPlaybackDuration?.source.rawValue ?? "nil")"
            )
            return
        }

        guard canSeek else {
            pendingDeferredSeek = PendingDeferredSeek(
                progress: clampedProgress,
                itemID: activeTrackIDForDiagnostics,
                token: currentPlaybackToken
            )
            pendingSeekProgress = clampedProgress
            logSeekRequest(prefix: "Queued seek", requestedProgress: clampedProgress, duration: currentResolvedDuration)
            return
        }

        performSeek(progress: clampedProgress, duration: currentResolvedDuration, player: player)
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
        resolvedPlaybackDuration = nil
        pendingDeferredSeek = nil
        logicalPlaybackAnchor = nil
        currentTransportStartSeconds = nil
        canSeek = false
        clearNowPlayingInfo()
    }

    func stopPlayback() {
        player?.pause()
        invalidatePendingSeek()
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
        cancelDurationResolution()
        resolvedPlaybackDuration = nil
        pendingDeferredSeek = nil
        hasCompletedCurrentTrack = false
        logicalPlaybackAnchor = nil
        currentTransportStartSeconds = nil
        canSeek = false
        refreshNowPlayingInfo()
    }

    func pauseAtEndOfQueue() {
        player?.pause()
        isPlaybackRequested = false
        cancelDeferredBufferingTransition()
        cancelBufferingRetry()
        bufferingRetryCount = 0
        if playbackDuration > 0 {
            playbackPosition = playbackDuration
        }
        refreshSeekAvailability()
        transitionPlaybackState(to: .paused)
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
        let nextPlaybackToken = UUID()

        let volume = await resolvePlaybackVolume(for: track)
        guard preparationID == playbackPreparationID else { return }

        currentPlaybackToken = nextPlaybackToken
        invalidatePendingSeek()
        resolvedPlaybackDuration = nil
        pendingDeferredSeek = nil
        hasCompletedCurrentTrack = false
        logicalPlaybackAnchor = nil
        currentTransportStartSeconds = transportStartSeconds(from: track.streamURL)
        canSeek = false
        lastPlaybackProgressDate = nil
        bufferingRetryCount = 0
        cancelBufferingRetry()
        context.timelineTracker?.beginTracking(track)
        context.libraryStore?.refreshRelatedAlbums(for: track)
        if let currentTransportStartSeconds {
            logDebug(
                "Detected stream transport start for \(track.title): " +
                    "\(formattedTimestamp(currentTransportStartSeconds)) from \(transportStartDescription(for: track.streamURL))"
            )
        }
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
        updatePlaybackTiming(from: item, track: track, playbackToken: nextPlaybackToken)
        resolvePlaybackDuration(
            from: item,
            preparationID: preparationID,
            track: track,
            playbackToken: nextPlaybackToken
        )
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

    private func formattedTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown" }
        let totalMilliseconds = Int((seconds * 1_000).rounded())
        let totalSeconds = totalMilliseconds / 1_000
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%d:%02d.%03d (%.3fs)", minutes, remainingSeconds, milliseconds, seconds)
    }

    private func formattedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "unknown" }
        return String(format: "%.2f%%", value * 100)
    }

    private enum PlaybackDurationSource: String {
        case plexTrack
        case trackMetadata
        case avPlayerItem
        case avAsset
        case fallback

        var isMetadata: Bool {
            switch self {
            case .plexTrack, .trackMetadata:
                return true
            case .avPlayerItem, .avAsset, .fallback:
                return false
            }
        }

        var isPlexSource: Bool {
            self == .plexTrack
        }
    }

    private struct ResolvedPlaybackDuration {
        let seconds: Double
        let source: PlaybackDurationSource
    }

    private struct PendingDeferredSeek {
        let progress: Double
        let itemID: String
        let token: UUID
    }

    private struct LogicalPlaybackAnchor {
        let mediaPositionSeconds: Double
        let playerPositionSeconds: Double
    }

    private var activeTrackIDForDiagnostics: String {
        _currentTrack?.ratingKey ?? _currentTrack?.id ?? nowPlaying.trackName
    }

    private func playbackTokenString(_ token: UUID) -> String {
        token.uuidString.lowercased()
    }

    private func describeDuration(_ duration: ResolvedPlaybackDuration?) -> String {
        guard let duration else { return "nil" }
        return "\(formattedTimestamp(duration.seconds)) source=\(duration.source.rawValue)"
    }

    private func setResolvedPlaybackDuration(
        _ duration: ResolvedPlaybackDuration,
        itemID: String,
        playbackToken: UUID
    ) {
        guard duration.seconds.isFinite, duration.seconds > 0 else { return }
        guard playbackToken == currentPlaybackToken, itemID == activeTrackIDForDiagnostics else {
            logDebug(
                "Ignored stale duration result for \(itemID): " +
                    "new=\(formattedTimestamp(duration.seconds)) source=\(duration.source.rawValue), " +
                    "token=\(playbackTokenString(playbackToken)), currentItem=\(activeTrackIDForDiagnostics), " +
                    "currentToken=\(playbackTokenString(currentPlaybackToken))"
            )
            return
        }

        if let current = resolvedPlaybackDuration,
           current.source.isMetadata,
           !duration.source.isMetadata {
            let mismatchRatio = abs(duration.seconds - current.seconds) / current.seconds
            if mismatchRatio > 0.02 {
                logDebug(
                    "Ignored AV duration for \(itemID): " +
                        "new=\(formattedTimestamp(duration.seconds)) source=\(duration.source.rawValue), " +
                        "existing=\(formattedTimestamp(current.seconds)) source=\(current.source.rawValue), " +
                        "mismatch=\(formattedPercent(mismatchRatio)), " +
                        "token=\(playbackTokenString(playbackToken))"
                )
            }
            return
        }

        let previousDescription = describeDuration(resolvedPlaybackDuration)
        resolvedPlaybackDuration = duration
        playbackDuration = max(duration.seconds, playbackPosition)
        logDebug(
            "Duration update for \(itemID): " +
                "new=\(formattedTimestamp(duration.seconds)) source=\(duration.source.rawValue), " +
                "previous=\(previousDescription), token=\(playbackTokenString(playbackToken))"
        )
    }

    private func maybeUpdateDurationFromAVPlayer(
        _ seconds: Double,
        source: PlaybackDurationSource,
        itemID: String,
        playbackToken: UUID
    ) {
        guard seconds.isFinite, seconds > 0 else { return }

        setResolvedPlaybackDuration(
            ResolvedPlaybackDuration(seconds: seconds, source: source),
            itemID: itemID,
            playbackToken: playbackToken
        )
    }

    private func resolvedMetadataDuration(for track: MediaTrack) -> ResolvedPlaybackDuration? {
        guard let durationMilliseconds = track.durationMilliseconds else { return nil }
        let seconds = Double(durationMilliseconds) / 1_000
        guard seconds.isFinite, seconds > 0 else { return nil }

        let source: PlaybackDurationSource = context.mediaService is PlexService ? .plexTrack : .trackMetadata
        return ResolvedPlaybackDuration(seconds: seconds, source: source)
    }

    private func formattedTimeRanges(_ ranges: [NSValue]?) -> String {
        guard let ranges, !ranges.isEmpty else { return "[]" }
        return ranges.map { value in
            let range = value.timeRangeValue
            let start = formattedTimestamp(range.start.seconds)
            let end = formattedTimestamp(CMTimeRangeGetEnd(range).seconds)
            return "[\(start) -> \(end)]"
        }.joined(separator: ", ")
    }

    private func firstTimeRangeStartSeconds(_ ranges: [NSValue]?) -> Double? {
        guard let start = ranges?.first?.timeRangeValue.start.seconds,
              start.isFinite,
              start >= 0 else {
            return nil
        }
        return start
    }

    private func transportStartSeconds(from url: URL) -> Double? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let queryItems = components.queryItems ?? []
        for name in ["offset", "start", "startTime", "startTimeOffset", "time"] {
            guard let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value,
                  let seconds = Double(value),
                  seconds.isFinite,
                  seconds > 0 else {
                continue
            }
            return name.caseInsensitiveCompare("time") == .orderedSame && seconds > 1_000 ? seconds / 1_000 : seconds
        }
        return nil
    }

    private func transportStartDescription(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return "stream URL"
        }

        for name in ["offset", "start", "startTime", "startTimeOffset", "time"] {
            if let item = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
               let value = item.value {
                return "query \(item.name)=\(value)"
            }
        }

        return "stream URL"
    }

    private func logSeekRequest(prefix: String, requestedProgress: Double, duration: ResolvedPlaybackDuration) {
        let itemDuration = player?.currentItem?.duration.seconds ?? -1
        let playerStatus = player?.currentItem?.status.rawValue ?? -1
        let currentTime = player?.currentTime().seconds ?? -1
        let transportStart = currentTransportStartSeconds.map(formattedTimestamp) ?? "none"
        logDebug(
            "\(prefix) \(nowPlaying.trackName): " +
                "itemID=\(activeTrackIDForDiagnostics), token=\(playbackTokenString(currentPlaybackToken)), " +
                "progress=\(formattedPercent(requestedProgress)), resolvedDuration=\(formattedTimestamp(duration.seconds)), " +
                "durationSource=\(duration.source.rawValue), playerStatus=\(playerStatus), " +
                "itemDuration=\(formattedTimestamp(itemDuration)), " +
                "currentTime=\(formattedTimestamp(currentTime)), " +
                "transportStart=\(transportStart), " +
                "loadedTimeRanges=\(formattedTimeRanges(player?.currentItem?.loadedTimeRanges)), " +
                "seekableTimeRanges=\(formattedTimeRanges(player?.currentItem?.seekableTimeRanges))"
        )
    }

    private func performSeek(progress: Double, duration: ResolvedPlaybackDuration, player: AVPlayer) {
        let rawTarget = duration.seconds * progress
        let safeTarget = progress >= 0.98 ? min(rawTarget, max(duration.seconds - 2, 0)) : rawTarget
        let targetSeconds = max(0, min(safeTarget, duration.seconds))
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let currentSeekID = nextSeekID()

        logSeekRequest(prefix: "Seeking", requestedProgress: progress, duration: duration)
        pendingDeferredSeek = nil
        pendingSeekProgress = progress
        playbackPosition = min(max(targetTime.seconds, 0), playbackDuration)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, currentSeekID == self.seekID else { return }
                let rawPlayerTime = player.currentTime().seconds
                if rawPlayerTime.isFinite {
                    self.logicalPlaybackAnchor = LogicalPlaybackAnchor(
                        mediaPositionSeconds: self.playbackPosition,
                        playerPositionSeconds: rawPlayerTime
                    )
                }
                self.logDebug(
                    "Seek completed \(self.nowPlaying.trackName): logical \(self.formattedTimestamp(self.playbackPosition)), " +
                        "rawPlayer \(self.formattedTimestamp(rawPlayerTime)), " +
                        "transportStart=\(self.currentTransportStartSeconds.map(self.formattedTimestamp) ?? "none"), " +
                        "loadedStart=\(self.firstTimeRangeStartSeconds(player.currentItem?.loadedTimeRanges).map(self.formattedTimestamp) ?? "none"), " +
                        "seekableStart=\(self.firstTimeRangeStartSeconds(player.currentItem?.seekableTimeRanges).map(self.formattedTimestamp) ?? "none"), " +
                        "duration \(self.formattedTimestamp(self.playbackDuration)), " +
                        "durationSource \(self.resolvedPlaybackDuration?.source.rawValue ?? "nil")"
                )
                self.pendingSeekProgress = nil
                self.refreshSeekAvailability()
                self.refreshNowPlayingInfo()
            }
        }
    }

    private func handlePlaybackEnded() {
        guard !hasCompletedCurrentTrack else { return }
        hasCompletedCurrentTrack = true
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
                        guard let track = self._currentTrack else { return }
                        self.updatePlaybackTiming(from: item, track: track, playbackToken: self.currentPlaybackToken)
                        self.refreshSeekAvailability()
                        self.applyPendingSeekIfNeeded()
                        if self.isPlaybackRequested {
                            self.transitionPlaybackState(to: .playing)
                            self.scheduleBufferingRetryIfNeeded()
                        }
                    case .failed:
                        self.canSeek = false
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
                    let clampedSeconds = self.logicalPlaybackPosition(forRawPlayerSeconds: seconds)
                    self.logPlaybackOverrunIfNeeded(rawPosition: seconds, logicalPosition: clampedSeconds)
                    if clampedSeconds > self.playbackPosition + 0.1 {
                        self.lastPlaybackProgressDate = Date()
                        if self.isPlaybackRequested {
                            self.cancelDeferredBufferingTransition()
                            self.cancelBufferingRetry()
                            self.bufferingRetryCount = 0
                            self.transitionPlaybackState(to: .playing)
                        }
                    }
                    self.playbackPosition = clampedSeconds
                }

                if let duration = player.currentItem?.duration.seconds,
                   duration.isFinite,
                   duration > 0 {
                    self.maybeUpdateDurationFromAVPlayer(
                        duration,
                        source: .avPlayerItem,
                        itemID: self.activeTrackIDForDiagnostics,
                        playbackToken: self.currentPlaybackToken
                    )
                    self.playbackPosition = self.clampedPlaybackPosition(self.playbackPosition)
                }

                self.refreshSeekAvailability()
                self.refreshNowPlayingInfo()
                self.delegate?.playbackEngine(self, didUpdatePosition: self.playbackPosition, duration: self.playbackDuration)
            }
        }
    }

    private func clampedPlaybackPosition(_ position: Double) -> Double {
        guard position.isFinite else { return 0 }
        let lowerBoundedPosition = max(0, position)
        guard playbackDuration > 0 else { return lowerBoundedPosition }
        return min(lowerBoundedPosition, playbackDuration)
    }

    private func logicalPlaybackPosition(forRawPlayerSeconds rawPlayerSeconds: Double) -> Double {
        guard let logicalPlaybackAnchor else {
            if let currentTransportStartSeconds,
               rawPlayerSeconds < currentTransportStartSeconds - 1 {
                return clampedPlaybackPosition(currentTransportStartSeconds + max(0, rawPlayerSeconds))
            }
            return clampedPlaybackPosition(rawPlayerSeconds)
        }

        let elapsedSinceAnchor = max(0, rawPlayerSeconds - logicalPlaybackAnchor.playerPositionSeconds)
        return clampedPlaybackPosition(logicalPlaybackAnchor.mediaPositionSeconds + elapsedSinceAnchor)
    }

    private func updatePlaybackTimingFromPlayer() {
        guard let player else { return }
        let currentTime = player.currentTime().seconds
        if currentTime.isFinite {
            playbackPosition = logicalPlaybackPosition(forRawPlayerSeconds: currentTime)
            logPlaybackOverrunIfNeeded(rawPosition: currentTime, logicalPosition: playbackPosition)
        }
    }

    private func refreshSeekAvailability() {
        canSeek = isCurrentItemSeekable
    }

    private func logPlaybackOverrunIfNeeded(rawPosition: Double, logicalPosition: Double) {
        guard rawPosition.isFinite,
              playbackDuration > 0,
              rawPosition > playbackDuration + 0.5 else {
            return
        }

        logDebug(
            "Playback exceeded known duration for \(nowPlaying.trackName): " +
                "rawPlayer \(formattedTimestamp(rawPosition)), logical \(formattedTimestamp(logicalPosition)), " +
                "known duration \(formattedTimestamp(playbackDuration)), " +
                "durationSource=\(resolvedPlaybackDuration?.source.rawValue ?? "nil"), " +
                "itemID=\(activeTrackIDForDiagnostics), token=\(playbackTokenString(currentPlaybackToken))"
        )
    }

    private var isCurrentItemSeekable: Bool {
        guard resolvedPlaybackDuration != nil,
              playbackDuration > 0,
              let item = player?.currentItem,
              item.status == .readyToPlay else {
            return false
        }

        return true
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

    private func updatePlaybackTiming(from item: AVPlayerItem, track: MediaTrack, playbackToken: UUID) {
        playbackPosition = 0

        if let metadataDuration = resolvedMetadataDuration(for: track) {
            setResolvedPlaybackDuration(
                metadataDuration,
                itemID: track.ratingKey ?? track.id,
                playbackToken: playbackToken
            )
            logDebug(
                "Loaded metadata duration for \(nowPlaying.trackName): " +
                    "\(formattedTimestamp(metadataDuration.seconds)) source=\(metadataDuration.source.rawValue)"
            )
        } else {
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 {
                maybeUpdateDurationFromAVPlayer(
                    duration,
                    source: .fallback,
                    itemID: track.ratingKey ?? track.id,
                    playbackToken: playbackToken
                )
                logDebug("Loaded fallback item duration for \(nowPlaying.trackName): \(formattedTimestamp(duration))")
            } else {
                playbackDuration = 0
                resolvedPlaybackDuration = nil
                logDebug("No duration available yet for \(nowPlaying.trackName)")
            }
        }

        let itemDuration = item.duration.seconds
        if itemDuration.isFinite, itemDuration > 0 {
            logDebug("Observed player item duration for \(nowPlaying.trackName): \(formattedTimestamp(itemDuration))")
        } else {
            logDebug("Player item duration unavailable for \(nowPlaying.trackName)")
        }
        refreshNowPlayingInfo()
    }

    private func resolvePlaybackDuration(
        from item: AVPlayerItem,
        preparationID: Int,
        track: MediaTrack,
        playbackToken: UUID
    ) {
        durationResolutionTask?.cancel()
        durationResolutionTask = Task { [weak self] in
            do {
                let duration = try await item.asset.load(.duration)
                guard !Task.isCancelled else { return }
                let seconds = duration.seconds

                await MainActor.run {
                    guard let self,
                          preparationID == self.playbackPreparationID,
                          self.player?.currentItem === item,
                          seconds.isFinite,
                          seconds > 0 else {
                        return
                    }

                    self.maybeUpdateDurationFromAVPlayer(
                        seconds,
                        source: .avAsset,
                        itemID: track.ratingKey ?? track.id,
                        playbackToken: playbackToken
                    )
                    self.playbackPosition = self.clampedPlaybackPosition(self.playbackPosition)
                    self.logDebug(
                        "Loaded asset duration for \(self.nowPlaying.trackName): " +
                            "\(self.formattedTimestamp(seconds)) source=\(PlaybackDurationSource.avAsset.rawValue)"
                    )
                    self.refreshSeekAvailability()
                    self.applyPendingSeekIfNeeded()
                    self.refreshNowPlayingInfo()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.logDebug("Playback duration lookup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelDurationResolution() {
        durationResolutionTask?.cancel()
        durationResolutionTask = nil
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

        guard let track = _currentTrack else { return }
        updatePlaybackTiming(from: item, track: track, playbackToken: currentPlaybackToken)
        resolvePlaybackDuration(
            from: item,
            preparationID: playbackPreparationID,
            track: track,
            playbackToken: currentPlaybackToken
        )
        if resumeTime > 1 {
            let retryPreparationID = playbackPreparationID
            let clampedResumeTime = clampedPlaybackPosition(resumeTime)
            playbackPosition = clampedResumeTime
            let targetTime = CMTime(seconds: clampedResumeTime, preferredTimescale: 600)
            player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self._currentTrack?.id == trackID,
                          self.playbackPreparationID == retryPreparationID,
                          let rawPlayerSeconds = self.player?.currentTime().seconds,
                          rawPlayerSeconds.isFinite else {
                        return
                    }
                    self.logicalPlaybackAnchor = LogicalPlaybackAnchor(
                        mediaPositionSeconds: clampedResumeTime,
                        playerPositionSeconds: rawPlayerSeconds
                    )
                    self.playbackPosition = clampedResumeTime
                }
            }
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
        pendingDeferredSeek = nil
    }

    private func applyPendingSeekIfNeeded() {
        guard canSeek,
              let pendingDeferredSeek,
              pendingDeferredSeek.itemID == activeTrackIDForDiagnostics,
              pendingDeferredSeek.token == currentPlaybackToken,
              let player,
              let resolvedPlaybackDuration else {
            return
        }

        self.pendingDeferredSeek = nil
        performSeek(progress: pendingDeferredSeek.progress, duration: resolvedPlaybackDuration, player: player)
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
