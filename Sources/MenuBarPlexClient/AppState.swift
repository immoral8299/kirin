import AVFoundation
import Foundation

@MainActor
final class AppState {
    let settingsStore = SettingsStore()
    let authService: PlexAuthService

    let libraryStore: LibraryStore
    let playbackEngine: PlaybackEngine
    let queueManager: QueueManager
    let timelineTracker: TimelineTracker

    private let context: StoreContext
    private let apiClient: PlexService

    // MARK: - Forwarded computed properties

    var playbackState: PlaybackState { playbackEngine.playbackState }
    var nowPlaying: TrackMetadata { playbackEngine.nowPlaying }
    var playbackPosition: Double { playbackEngine.playbackPosition }
    var playbackDuration: Double { playbackEngine.playbackDuration }
    var pendingSeekProgress: Double? { playbackEngine.pendingSeekProgress }
    var isShuffleEnabled: Bool { queueManager.isShuffleEnabled }
    var recentlyPlayedAlbums: [PlexAlbum] { libraryStore.recentlyPlayedAlbums }
    var recentlyAddedAlbums: [PlexAlbum] { libraryStore.recentlyAddedAlbums }
    var playlists: [PlexPlaylist] { libraryStore.playlists }
    var stations: [PlexStation] { libraryStore.stations }
    var isLoadingLibrary: Bool { libraryStore.isLoadingLibrary }
    var libraryLoadError: String? { libraryStore.libraryLoadError }
    var availableServers: [PlexServer] { libraryStore.availableServers }
    var availableLibraries: [PlexMusicLibrary] { libraryStore.availableLibraries }
    var currentLoadingMessage: String? { libraryStore.currentLoadingMessage }
    var visiblePlayQueue: [PlexTrack] { queueManager.visiblePlayQueue }
    var relatedAlbums: [PlexAlbum] { libraryStore.relatedAlbums }
    var isQueueOperationInProgress: Bool { queueManager.isQueueOperationInProgress }
    var shouldPresentInitialLoadFailure: Bool { libraryStore.shouldPresentInitialLoadFailure }

    // MARK: - Init

    init() {
        authService = PlexAuthService()
        apiClient = PlexService(authService: authService)
        context = StoreContext(plexService: apiClient, settingsStore: settingsStore)
        libraryStore = LibraryStore(context: context)
        playbackEngine = PlaybackEngine(context: context)
        queueManager = QueueManager(context: context)
        timelineTracker = TimelineTracker(context: context)

        context.libraryStore = libraryStore
        context.playbackEngine = playbackEngine
        context.queueManager = queueManager
        context.timelineTracker = timelineTracker

        playbackEngine.delegate = self

        if authService.authToken != nil {
            Task {
                await libraryStore.reloadPlexData()
            }
        }
    }

    // MARK: - Computed properties

    var selectedServerID: String? { settingsStore.settings.selectedServerID }
    var selectedLibraryID: String? { settingsStore.settings.selectedLibraryID }
    var selectedServerName: String? { libraryStore.selectedServerName }
    var selectedLibraryTitle: String? { libraryStore.selectedLibraryTitle }
    var authenticatedUsername: String? {
        guard case let .authenticated(username) = authService.status.state else {
            return nil
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUsername.isEmpty ? nil : trimmedUsername
    }

    var isAuthenticated: Bool { authService.authToken != nil }
    var isLoudnessLevelingEnabled: Bool { settingsStore.settings.loudnessLevelingEnabled }
    var listenedThresholdPercentage: Int { timelineTracker.listenedThresholdPercentage }
    var themePreference: AppThemePreference { settingsStore.settings.themePreference }

    var hasExistingContent: Bool { libraryStore.hasExistingContent }
    var loadingTargetDescription: String? { libraryStore.loadingTargetDescription }
    var shouldPromptForServerSelection: Bool { libraryStore.shouldPromptForServerSelection }
    var playbackProgress: Double { playbackEngine.playbackProgress }
    var hasEditablePlayQueue: Bool { queueManager.hasEditablePlayQueue }
    var currentPlayQueueTrackID: String? { queueManager.currentPlayQueueTrackID }

    var statusLine: String {
        if !shouldPreserveNowPlayingStatus,
           let transientStatusLine {
            return transientStatusLine
        }

        if nowPlaying == .placeholder,
           let loadingTargetDescription {
            return loadingTargetDescription
        }

        return settingsStore.settings.menuBarFormat.render(with: nowPlaying)
    }

    var statusIconName: String {
        if !shouldPreserveNowPlayingStatus,
           isShowingTransientStatus {
            return PlaybackState.buffering.statusSystemImageName
        }
        return playbackState.statusSystemImageName
    }

    private var transientStatusLine: String? {
        switch authService.status.state {
        case .requestingPin:
            return "Connecting..."
        case .waitingForBrowserLogin:
            return "Waiting for login..."
        case let .failed(message):
            return message
        case .idle:
            return isLoadingLibrary ? "Loading library..." : nil
        case .authenticated:
            if isLoadingLibrary {
                return currentLoadingStatusLine
            }
            if let libraryLoadError {
                return libraryLoadError
            }
            return nil
        }
    }

    private var currentLoadingStatusLine: String {
        libraryStore.currentLoadingStatusLine
    }

    private var isShowingTransientStatus: Bool {
        transientStatusLine != nil
    }

    private var shouldPreserveNowPlayingStatus: Bool {
        nowPlaying != .placeholder &&
            (playbackState == .playing || (playbackState == .buffering && isPlaybackRequested))
    }

    private var isPlaybackRequested: Bool {
        playbackEngine.playbackState == .buffering || playbackState == .playing
    }

    // MARK: - Auth

    func beginPlexLogin() {
        Task {
            await authService.beginLogin()
            await libraryStore.reloadPlexData()
        }
    }

    func signOut() {
        timelineTracker.stopTracking()
        playbackEngine.stopPlayback()
        playbackEngine.resetForNewTrack()
        queueManager.resetQueue()
        libraryStore.resetPlaybackPreview()
        authService.signOut()
        settingsStore.settings.selectedServerID = nil
        settingsStore.settings.selectedLibraryID = nil
        libraryStore.availableServers = []
        libraryStore.availableLibraries = []
        libraryStore.recentlyPlayedAlbums = []
        libraryStore.recentlyAddedAlbums = []
        libraryStore.playlists = []
        libraryStore.stations = []
        libraryStore.libraryLoadError = nil
        libraryStore.currentLoadingMessage = nil
        libraryStore.shouldPresentInitialLoadFailure = false
        playbackEngine.clearCaches()
    }

    // MARK: - Server & Library

    func selectServer(id: String) {
        libraryStore.selectServer(id: id)
    }

    func selectLibrary(id: String) {
        libraryStore.selectLibrary(id: id)
    }

    func refreshCurrentLibraryContent() {
        libraryStore.refreshCurrentLibraryContent()
    }

    func refreshServersAndLibraries() {
        libraryStore.refreshServersAndLibraries()
    }

    func dismissLibraryLoadError() {
        libraryStore.dismissLibraryLoadError()
    }

    func didPresentInitialLoadFailure() {
        libraryStore.didPresentInitialLoadFailure()
    }

    // MARK: - Playback

    func togglePlayback() {
        playbackEngine.togglePlayback()
    }

    func nextTrack() {
        queueManager.advanceToNextTrack()
    }

    func previousTrack() {
        queueManager.goToPreviousTrack()
    }

    func seekToProgress(_ progress: Double) {
        playbackEngine.seekToProgress(progress)
    }

    func toggleShuffle() {
        queueManager.toggleShuffle()
    }

    func setLoudnessLevelingEnabled(_ isEnabled: Bool) {
        playbackEngine.setLoudnessLevelingEnabled(isEnabled)
    }

    func setListenedThresholdPercentage(_ percentage: Int) {
        timelineTracker.setListenedThresholdPercentage(percentage)
    }

    func setThemePreference(_ preference: AppThemePreference) {
        settingsStore.settings.themePreference = preference
    }

    // MARK: - Playables

    func playAlbum(_ album: PlexAlbum) {
        queueManager.playAlbum(album)
    }

    func playAlbum(_ album: PlexAlbum, source: String?) {
        queueManager.playAlbum(album, source: source)
    }

    func playPlaylist(_ playlist: PlexPlaylist) {
        queueManager.playPlaylist(playlist)
    }

    func playStation(_ station: PlexStation) {
        queueManager.playStation(station)
    }

    func enqueueAlbum(_ album: PlexAlbum, playNext: Bool) {
        queueManager.enqueueAlbum(album, playNext: playNext)
    }

    func enqueuePlaylist(_ playlist: PlexPlaylist, playNext: Bool) {
        queueManager.enqueuePlaylist(playlist, playNext: playNext)
    }

    func enqueueStation(_ station: PlexStation, playNext: Bool) {
        queueManager.enqueueStation(station, playNext: playNext)
    }

    func playStationRecommendation(_ recommendation: PlexStationRecommendation) {
        queueManager.playStationRecommendation(recommendation)
    }

    func enqueueStationRecommendation(_ recommendation: PlexStationRecommendation) {
        queueManager.enqueueStationRecommendation(recommendation)
    }

    // MARK: - Queue

    func refreshPlayQueue() {
        queueManager.refreshPlayQueue()
    }

    func selectPlayQueueTrack(id: String) {
        queueManager.selectPlayQueueTrack(id: id)
    }

    func removePlayQueueTrack(id: String) {
        queueManager.removePlayQueueTrack(id: id)
    }

    func movePlayQueueTrack(id: String, before targetID: String) {
        queueManager.movePlayQueueTrack(id: id, before: targetID)
    }

    func clearUpcomingPlayQueueTracks() {
        queueManager.clearUpcomingPlayQueueTracks()
    }

}

// MARK: - PlaybackEngineDelegate

extension AppState: PlaybackEngineDelegate {
    func playbackEngineDidEndCurrentTrack(_ engine: PlaybackEngine) {
        timelineTracker.markTrackedTrackListenedIfNeeded(force: true)
        timelineTracker.stopTracking()
        queueManager.handleTrackEnded()
    }

    func playbackEngine(_ engine: PlaybackEngine, didUpdatePosition position: Double, duration: Double) {
        timelineTracker.markTrackedTrackListenedIfNeeded()
    }

    func playbackEngine(_ engine: PlaybackEngine, didTransitionTo state: PlaybackState) {
        timelineTracker.playbackStateDidChange(to: state)
    }
}
