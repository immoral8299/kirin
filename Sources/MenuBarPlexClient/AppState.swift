import AVFoundation
import Combine
import Foundation

@MainActor
final class AppState {
    let settingsStore = SettingsStore()
    let updateChecker = UpdateChecker()
    let authService: PlexAuthService

    let libraryStore: LibraryStore
    let playbackEngine: PlaybackEngine
    let queueManager: QueueManager
    let timelineTracker: TimelineTracker

    private let context: StoreContext
    private var mediaService: MediaService
    private var cancellables = Set<AnyCancellable>()
    private var hasRequestedFirstPanelUpdateCheck = false

    // MARK: - Forwarded computed properties

    var playbackState: PlaybackState { playbackEngine.playbackState }
    var nowPlaying: TrackMetadata { playbackEngine.nowPlaying }
    var playbackPosition: Double { playbackEngine.playbackPosition }
    var playbackDuration: Double { playbackEngine.playbackDuration }
    var pendingSeekProgress: Double? { playbackEngine.pendingSeekProgress }
    var isShuffleEnabled: Bool { queueManager.isShuffleEnabled }
    var recentlyPlayedAlbums: [MediaAlbum] { libraryStore.recentlyPlayedAlbums }
    var recentlyAddedAlbums: [MediaAlbum] { libraryStore.recentlyAddedAlbums }
    var playlists: [MediaPlaylist] { libraryStore.playlists }
    var stations: [MediaStation] { libraryStore.stations }
    var isLoadingLibrary: Bool { libraryStore.isLoadingLibrary }
    var libraryLoadError: LibraryLoadError? { libraryStore.libraryLoadError }
    var availableServers: [MediaServer] { libraryStore.availableServers }
    var availableLibraries: [MediaMusicLibrary] { libraryStore.availableLibraries }
    var currentLoadingMessage: String? { libraryStore.currentLoadingMessage }
    var visiblePlayQueue: [MediaTrack] { queueManager.visiblePlayQueue }
    var relatedAlbums: [MediaAlbum] { libraryStore.relatedAlbums }
    var isQueueOperationInProgress: Bool { queueManager.isQueueOperationInProgress }
    var canGoToPreviousTrack: Bool { queueManager.canGoToPreviousTrack }
    var canGoToNextTrack: Bool { queueManager.canGoToNextTrack }
    var canShuffle: Bool { queueManager.canShuffle }
    var shouldPresentInitialLoadFailure: Bool { libraryStore.shouldPresentInitialLoadFailure }

    // MARK: - Init

    init() {
        authService = PlexAuthService()

        let keychain = KeychainStore()

        if settingsStore.settings.mediaSource == .unspecified {
            if authService.authToken != nil {
                settingsStore.settings.mediaSource = .plex
            } else if Self.hasStoredNavidromePassword(config: settingsStore.settings.navidromeConfig, keychain: keychain) {
                settingsStore.settings.mediaSource = .navidrome
            }
        }

        let seedSettings = settingsStore.settings
        switch settingsStore.settings.mediaSource {
        case .plex:
            if case let .authenticated(username) = authService.status.state {
                settingsStore.switchProfile(
                    to: SettingsStore.plexProfileKey(username: username),
                    seed: seedSettings
                )
                settingsStore.settings.mediaSource = .plex
            }
        case .navidrome:
            let config = settingsStore.settings.navidromeConfig
            if Self.hasStoredNavidromePassword(config: config, keychain: keychain) {
                settingsStore.switchProfile(
                    to: SettingsStore.navidromeProfileKey(connectionName: config.name),
                    seed: seedSettings
                )
                settingsStore.settings.mediaSource = .navidrome
                settingsStore.settings.navidromeConfig = config
            } else {
                settingsStore.settings.mediaSource = .unspecified
            }
        case .local:
            settingsStore.switchProfile(
                to: SettingsStore.localProfileKey(),
                seed: seedSettings
            )
            settingsStore.settings.mediaSource = .local
        case .unspecified:
            break
        }

        switch settingsStore.settings.mediaSource {
        case .navidrome where Self.hasStoredNavidromePassword(config: settingsStore.settings.navidromeConfig, keychain: keychain):
            let config = settingsStore.settings.navidromeConfig
            let password = keychain.read(key: config.keychainKey) ?? ""
            mediaService = NavidromeService(config: config, password: password)
        case .local:
            mediaService = LocalService()
        default:
            mediaService = PlexService(authService: authService)
        }

        context = StoreContext(mediaService: mediaService, settingsStore: settingsStore)
        libraryStore = LibraryStore(context: context)
        playbackEngine = PlaybackEngine(context: context)
        queueManager = QueueManager(context: context)
        timelineTracker = TimelineTracker(context: context)

        context.libraryStore = libraryStore
        context.playbackEngine = playbackEngine
        context.queueManager = queueManager
        context.timelineTracker = timelineTracker

        playbackEngine.delegate = self
        bindAuthProfileUpdates()

        switch settingsStore.settings.mediaSource {
        case .plex where authService.authToken != nil:
            Task {
                await libraryStore.reloadPlexData()
            }
        case .navidrome:
            Task {
                await libraryStore.reloadData()
            }
        case .local:
            Task {
                await restorePersistedLocalQueue()
            }
        default:
            break
        }

        Task {
            await updateChecker.checkForUpdatesIfNeeded()
        }
    }

    /// Checks for app updates the first time the panel is opened.
    ///
    /// Use this method to trigger a one-time update check when the menu bar panel
    /// becomes visible for the first time in a release build.
    /// - Note: This does nothing in `DEBUG` builds.
    func checkForUpdatesOnFirstPanelOpen() async {
        #if DEBUG
        return
        #else
        guard !hasRequestedFirstPanelUpdateCheck else { return }
        hasRequestedFirstPanelUpdateCheck = true
        await updateChecker.checkForUpdates()
        #endif
    }

    private func migrateMediaSourceIfNeeded() {
        guard settingsStore.settings.mediaSource == .unspecified else { return }
        if authService.authToken != nil {
            settingsStore.settings.mediaSource = .plex
        } else if hasStoredNavidromePassword() {
            settingsStore.settings.mediaSource = .navidrome
        }
    }

    // MARK: - Local mode

    var isLocalMode: Bool { activeMediaSource == .local }

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

    var activeMediaSource: ActiveMediaSource {
        get { settingsStore.settings.mediaSource }
        set { settingsStore.settings.mediaSource = newValue }
    }

    var isConfigured: Bool {
        switch activeMediaSource {
        case .unspecified: return false
        case .plex: return authService.authToken != nil
        case .navidrome:
            return settingsStore.settings.navidromeConfig.isFilled && hasStoredNavidromePassword()
        case .local: return true
        }
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
        guard isConfigured else {
            return "Configure connection"
        }

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
            return PlaybackStateIcon.statusSystemImageName(for: .buffering)
        }
        return PlaybackStateIcon.statusSystemImageName(for: playbackState)
    }

    private var transientStatusLine: String? {
        switch authService.status.state {
        case .requestingPin:
            return "Connecting..."
        case .waitingForBrowserLogin:
            return "Waiting for login..."
        case let .failed(message):
            return message
        case .idle, .authenticated:
            if isLoadingLibrary {
                return currentLoadingStatusLine
            }
            if let libraryLoadError {
                return libraryLoadError.message
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
        settingsStore.settings.mediaSource = .plex
        switchMediaService(to: PlexService(authService: authService))
        Task {
            await authService.beginLogin()
            activatePlexSettingsProfile()
            settingsStore.settings.mediaSource = .plex
            await libraryStore.reloadPlexData()
        }
    }

    func verifyNavidromeConnection(config: NavidromeServerConfig, password: String) async throws {
        let baseURL = URL(string: config.publicUrl ?? config.url) ?? URL(string: config.url)!
        let client = SubsonicClient(baseURL: baseURL, username: config.username, password: password, session: .shared)
        let response = try await client.ping()
        guard response.status == "ok" else {
            throw NavidromeError.authenticationFailed
        }
    }

    func configureNavidrome(_ config: NavidromeServerConfig, password: String) {
        let keychain = KeychainStore()
        keychain.save(password, key: config.keychainKey)
        var seedSettings = AppSettings.default
        seedSettings.mediaSource = .navidrome
        seedSettings.navidromeConfig = config
        settingsStore.switchProfile(
            to: SettingsStore.navidromeProfileKey(connectionName: config.name),
            seed: seedSettings
        )
        settingsStore.settings.mediaSource = .navidrome
        settingsStore.settings.navidromeConfig = config
        settingsStore.settings.selectedServerID = nil
        settingsStore.settings.selectedLibraryID = nil
        switchMediaService(to: NavidromeService(config: config, password: password))
        libraryStore.resetContent()
        queueManager.resetQueue()
        playbackEngine.stopPlayback()
        playbackEngine.resetForNewTrack()
        Task {
            await libraryStore.reloadData()
        }
    }

    func signOut() {
        let keychain = KeychainStore()
        let wasNavidrome = activeMediaSource == .navidrome
        let navidromeConfig = settingsStore.settings.navidromeConfig
        if wasNavidrome, navidromeConfig.isFilled {
            keychain.delete(key: navidromeConfig.keychainKey)
        }

        timelineTracker.stopTracking()
        playbackEngine.stopPlayback()
        playbackEngine.resetForNewTrack()
        queueManager.resetQueue()
        libraryStore.resetPlaybackPreview()
        authService.signOut()
        switchMediaService(to: PlexService(authService: authService))
        settingsStore.settings.selectedServerID = nil
        settingsStore.settings.selectedLibraryID = nil
        settingsStore.settings.mediaSource = .unspecified
        settingsStore.settings.navidromeConfig = wasNavidrome ? navidromeConfig : .default
        libraryStore.availableServers = []
        libraryStore.availableLibraries = []
        libraryStore.recentlyPlayedAlbums = []
        libraryStore.recentlyAddedAlbums = []
        libraryStore.playlists = []
        libraryStore.stations = []
        libraryStore.dismissLibraryLoadError()
        libraryStore.currentLoadingMessage = nil
        libraryStore.shouldPresentInitialLoadFailure = false
        playbackEngine.clearCaches()
    }

    func configureLocalFiles() {
        settingsStore.switchProfile(
            to: SettingsStore.localProfileKey(),
            seed: settingsStore.settings
        )
        settingsStore.settings.mediaSource = .local
        settingsStore.settings.selectedServerID = nil
        settingsStore.settings.selectedLibraryID = nil
        switchMediaService(to: LocalService())
        libraryStore.resetContent()
        queueManager.resetQueue()
        persistLocalQueue()
        playbackEngine.stopPlayback()
        playbackEngine.resetForNewTrack()
    }

    func selectLocalFilesForImport() async -> LocalFileImportResult {
        await LocalFileImporter.selectFilesAndFolders()
    }

    func buildLocalTracks(from urls: [URL]) async -> LocalFileImportResult {
        await LocalFileImporter.buildTracks(from: urls)
    }

    func playLocalTracks(_ tracks: [MediaTrack]) {
        guard !tracks.isEmpty else { return }
        activateLocalModeIfNeeded(resetPlayback: false)
        queueManager.replaceLocalQueue(with: tracks, startPlayback: true)
        persistLocalQueue()
    }

    func addLocalTracksNext(_ tracks: [MediaTrack]) {
        guard !tracks.isEmpty else { return }
        activateLocalModeIfNeeded(resetPlayback: false)
        queueManager.insertLocalTracksNext(tracks)
        persistLocalQueue()
    }

    func appendLocalTracks(_ tracks: [MediaTrack]) {
        guard !tracks.isEmpty else { return }
        activateLocalModeIfNeeded(resetPlayback: false)
        queueManager.appendLocalTracks(tracks)
        persistLocalQueue()
    }

    func openLocalFilesFromFinder(_ urls: [URL]) async {
        let result = await buildLocalTracks(from: urls)
        guard !result.tracks.isEmpty else { return }
        playLocalTracks(result.tracks)
    }

    private func activateLocalModeIfNeeded(resetPlayback: Bool) {
        guard activeMediaSource != .local else { return }
        settingsStore.switchProfile(
            to: SettingsStore.localProfileKey(),
            seed: settingsStore.settings
        )
        settingsStore.settings.mediaSource = .local
        settingsStore.settings.selectedServerID = nil
        settingsStore.settings.selectedLibraryID = nil
        switchMediaService(to: LocalService())
        libraryStore.resetContent()
        if resetPlayback {
            queueManager.resetQueue()
            persistLocalQueue()
            playbackEngine.stopPlayback()
            playbackEngine.resetForNewTrack()
        }
    }

    private func restorePersistedLocalQueue() async {
        let savedQueue = settingsStore.settings.localQueue
        guard !savedQueue.filePaths.isEmpty else { return }

        let existingFileURLs = savedQueue.filePaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingFileURLs.isEmpty else {
            settingsStore.settings.localQueue = .default
            return
        }

        let result = await LocalFileImporter.buildTracks(from: existingFileURLs)
        guard !result.tracks.isEmpty else {
            settingsStore.settings.localQueue = .default
            return
        }

        queueManager.restoreLocalQueue(result.tracks, currentTrackID: savedQueue.currentTrackID)
        persistLocalQueue()
    }

    private func persistLocalQueue() {
        guard activeMediaSource == .local else { return }

        let filePaths = queueManager.allTracks.compactMap { track -> String? in
            if track.streamURL.isFileURL {
                return track.streamURL.standardizedFileURL.path
            }
            return track.id.hasPrefix("/") ? track.id : nil
        }

        settingsStore.settings.localQueue = LocalQueueSettings(
            filePaths: filePaths,
            currentTrackID: queueManager.currentPlayQueueTrackID
        )
    }

    private func switchMediaService(to service: MediaService) {
        mediaService = service
        context.mediaService = service
    }

    private func hasStoredNavidromePassword(keychain: KeychainStore = KeychainStore()) -> Bool {
        Self.hasStoredNavidromePassword(config: settingsStore.settings.navidromeConfig, keychain: keychain)
    }

    private static func hasStoredNavidromePassword(config: NavidromeServerConfig, keychain: KeychainStore) -> Bool {
        guard config.isFilled,
              let password = keychain.read(key: config.keychainKey) else {
            return false
        }
        return !password.isEmpty
    }

    private func activatePlexSettingsProfile(seed: AppSettings? = nil) {
        guard let username = authenticatedUsername else { return }
        settingsStore.switchProfile(
            to: SettingsStore.plexProfileKey(username: username),
            seed: seed
        )
    }

    private func bindAuthProfileUpdates() {
        authService.$status
            .sink { [weak self] status in
                guard let self,
                      self.settingsStore.settings.mediaSource == .plex,
                      case let .authenticated(username) = status.state,
                      !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }

                self.settingsStore.switchProfile(
                    to: SettingsStore.plexProfileKey(username: username),
                    seed: self.settingsStore.settings
                )
                self.settingsStore.settings.mediaSource = .plex
            }
            .store(in: &cancellables)
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
        if playbackEngine.currentTrack == nil,
           queueManager.currentTrack != nil {
            queueManager.playCurrentQueueTrack()
            return
        }

        playbackEngine.togglePlayback()
    }

    func nextTrack() {
        queueManager.advanceToNextTrack()
        persistLocalQueue()
    }

    func previousTrack() {
        queueManager.goToPreviousTrack()
        persistLocalQueue()
    }

    func seekToProgress(_ progress: Double) {
        playbackEngine.seekToProgress(progress)
    }

    func toggleShuffle() {
        queueManager.toggleShuffle()
        persistLocalQueue()
    }

    func setLoudnessLevelingEnabled(_ isEnabled: Bool) {
        playbackEngine.setLoudnessLevelingEnabled(isEnabled)
    }

    func setFallbackLoudnessGainDecibels(_ decibels: Int) {
        playbackEngine.setFallbackLoudnessGainDecibels(decibels)
    }

    func setListenedThresholdPercentage(_ percentage: Int) {
        timelineTracker.setListenedThresholdPercentage(percentage)
    }

    func setThemePreference(_ preference: AppThemePreference) {
        settingsStore.settings.themePreference = preference
    }

    func searchLibrary(query: String, limit: Int = 20) async throws -> MediaSearchResults {
        try await mediaService.searchLibrary(query: query, limit: limit)
    }

    // MARK: - Playables

    func playAlbum(_ album: MediaAlbum) {
        queueManager.playAlbum(album)
    }

    func playPlaylist(_ playlist: MediaPlaylist) {
        queueManager.playPlaylist(playlist)
    }

    func playStation(_ station: MediaStation) {
        queueManager.playStation(station)
    }

    func playTracks(_ tracks: [MediaTrack], startingAt trackID: String?) {
        queueManager.playTracks(tracks, startingAt: trackID)
    }

    func enqueueAlbum(_ album: MediaAlbum, playNext: Bool) {
        queueManager.enqueueAlbum(album, playNext: playNext)
    }

    func enqueuePlaylist(_ playlist: MediaPlaylist, playNext: Bool) {
        queueManager.enqueuePlaylist(playlist, playNext: playNext)
    }

    func enqueueStation(_ station: MediaStation, playNext: Bool) {
        queueManager.enqueueStation(station, playNext: playNext)
    }

    func enqueueTracks(_ tracks: [MediaTrack], playNext: Bool) {
        queueManager.enqueueTracks(tracks, playNext: playNext)
    }

    func playStationRecommendation(_ recommendation: MediaStationRecommendation) {
        queueManager.playStationRecommendation(recommendation)
    }

    func enqueueStationRecommendation(_ recommendation: MediaStationRecommendation, playNext: Bool) {
        queueManager.enqueueStationRecommendation(recommendation, playNext: playNext)
    }

    func selectPlayQueueTrack(id: String) {
        queueManager.selectPlayQueueTrack(id: id)
        persistLocalQueue()
    }

    func removePlayQueueTrack(id: String) {
        queueManager.removePlayQueueTrack(id: id)
        persistLocalQueue()
    }

    func movePlayQueueTrack(id: String, before targetID: String?) {
        queueManager.movePlayQueueTrack(id: id, before: targetID)
        persistLocalQueue()
    }

    func clearUpcomingPlayQueueTracks() {
        queueManager.clearUpcomingPlayQueueTracks()
        persistLocalQueue()
    }

}

// MARK: - PlaybackEngineDelegate

extension AppState: PlaybackEngineDelegate {
    func playbackEngineDidEndCurrentTrack(_ engine: PlaybackEngine) {
        timelineTracker.markTrackedTrackListenedIfNeeded(force: true)
        timelineTracker.stopTracking()
        queueManager.handleTrackEnded()
        persistLocalQueue()
    }

    func playbackEngine(_ engine: PlaybackEngine, didUpdatePosition position: Double, duration: Double) {
        timelineTracker.markTrackedTrackListenedIfNeeded()
    }

    func playbackEngine(_ engine: PlaybackEngine, didTransitionTo state: PlaybackState) {
        timelineTracker.playbackStateDidChange(to: state)
    }

    func playbackEngineDidRequestTogglePlayback(_ engine: PlaybackEngine) {
        togglePlayback()
    }

    func playbackEngineDidRequestNextTrack(_ engine: PlaybackEngine) {
        nextTrack()
    }

    func playbackEngineDidRequestPreviousTrack(_ engine: PlaybackEngine) {
        previousTrack()
    }

    func playbackEngine(_ engine: PlaybackEngine, didRequestSeekTo position: Double) {
        guard playbackDuration > 0 else { return }
        seekToProgress(position / playbackDuration)
    }
}
