import AVFoundation
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .paused
    @Published var nowPlaying: TrackMetadata = .placeholder
    @Published var playbackPosition: Double = 0
    @Published var playbackDuration: Double = 0
    @Published var pendingSeekProgress: Double?
    @Published var isShuffleEnabled = false
    @Published var recentlyPlayedAlbums: [PlexAlbum] = []
    @Published var recentlyAddedAlbums: [PlexAlbum] = []
    @Published var playlists: [PlexPlaylist] = []
    @Published var stations: [PlexStation] = []
    @Published var isLoadingLibrary = false
    @Published var libraryLoadError: String?
    @Published var availableServers: [PlexServer] = []
    @Published var availableLibraries: [PlexMusicLibrary] = []
    @Published var currentLoadingMessage: String?
    @Published private(set) var visiblePlayQueue: [PlexTrack] = []
    @Published private(set) var relatedAlbums: [PlexAlbum] = []
    @Published private(set) var isQueueOperationInProgress = false
    @Published private(set) var shouldPresentInitialLoadFailure = false

    let settingsStore = SettingsStore()
    let authService = PlexAuthService()

    private let apiClient = PlexAPIClient()
    private let homeFetchLimit = 12
    private var cancellables = Set<AnyCancellable>()

    private enum PlaybackSource {
        case album(PlexAlbum, PlexMusicLibrary)
        case playlist(PlexPlaylist)
        case station(PlexStation)
    }

    private var orderedPlaybackQueue: [PlexTrack] = []
    private var playbackQueue: [PlexTrack] = []
    private var usesServerManagedQueueOrder = false
    private var activePlaybackSource: PlaybackSource?
    private var currentQueueIndex: Int = 0
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playerItemEndObserver: AnyCancellable?
    private var playerTimeControlStatusObserver: AnyCancellable?
    private var playbackPreparationID: Int = 0
    private var seekID: Int = 0
    private var isPlaybackRequested = false
    private var loudnessGainCache: [String: Float] = [:]
    private var missingLoudnessAnalysisTrackIDs = Set<String>()
    private var activeServerPlayQueue: ServerPlayQueueContext?
    private var trackedTrack: PlexTrack?
    private var hasMarkedTrackedTrackListened = false
    private var lastTimelineReportDate: Date?
    private var timelineReportTask: Task<Void, Never>?
    private var relatedAlbumsTask: Task<Void, Never>?
    private var relatedAlbumsRatingKey: String?
    private let timelineReportInterval: TimeInterval = 10

    private struct ServerPlayQueueContext {
        let id: Int
        let itemCount: Int
    }

    init() {
        bindChildObjects()

        if authService.authToken != nil {
            Task {
                await reloadPlexData()
            }
        }
    }

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
        if let currentLoadingMessage {
            return currentLoadingMessage
        }

        return "Loading library..."
    }

    private var isShowingTransientStatus: Bool {
        transientStatusLine != nil
    }

    private var shouldPreserveNowPlayingStatus: Bool {
        nowPlaying != .placeholder &&
            (playbackState == .playing || (playbackState == .buffering && isPlaybackRequested))
    }

    var isAuthenticated: Bool {
        authService.authToken != nil
    }

    var authenticatedUsername: String? {
        guard case let .authenticated(username) = authService.status.state else {
            return nil
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUsername.isEmpty ? nil : trimmedUsername
    }

    var isLoudnessLevelingEnabled: Bool {
        settingsStore.settings.loudnessLevelingEnabled
    }

    var listenedThresholdPercentage: Int {
        settingsStore.settings.listenedThresholdPercentage
    }

    var themePreference: AppThemePreference {
        settingsStore.settings.themePreference
    }

    var selectedServerID: String? {
        settingsStore.settings.selectedServerID
    }

    var selectedLibraryID: String? {
        settingsStore.settings.selectedLibraryID
    }

    var selectedServerName: String? {
        selectedServer?.name
    }

    var selectedLibraryTitle: String? {
        selectedLibrary?.title
    }

    var hasExistingContent: Bool {
        !recentlyPlayedAlbums.isEmpty || !recentlyAddedAlbums.isEmpty || !playlists.isEmpty || !stations.isEmpty
    }

    var loadingTargetDescription: String? {
        guard let serverName = selectedServerName, let libraryTitle = selectedLibraryTitle else {
            return nil
        }

        return "\(serverName) / \(libraryTitle)"
    }

    var shouldPromptForServerSelection: Bool {
        isAuthenticated && !availableServers.isEmpty && selectedServer == nil
    }

    var playbackProgress: Double {
        if let pendingSeekProgress {
            return pendingSeekProgress
        }

        guard playbackDuration > 0 else { return 0 }
        return min(max(playbackPosition / playbackDuration, 0), 1)
    }

    var hasEditablePlayQueue: Bool {
        activeServerPlayQueue != nil
    }

    var currentPlayQueueTrackID: String? {
        currentTrack?.id
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

    func nextTrack() {
        guard !playbackQueue.isEmpty else { return }
        let nextIndex = min(currentQueueIndex + 1, playbackQueue.count - 1)
        guard nextIndex != currentQueueIndex else { return }

        currentQueueIndex = nextIndex
        Task {
            await playCurrentTrack()
            await refreshServerQueueAfterPlaybackAdvance()
        }
    }

    func previousTrack() {
        guard !playbackQueue.isEmpty else { return }
        let previousIndex = max(currentQueueIndex - 1, 0)
        guard previousIndex != currentQueueIndex else { return }

        currentQueueIndex = previousIndex
        Task {
            await playCurrentTrack()
            await refreshServerQueueAfterPlaybackAdvance()
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
                self.reportTrackedPlaybackTimeline(state: self.playbackState)
                self.markTrackedTrackListenedIfNeeded()
            }
        }
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()

        if let activeServerPlayQueue,
           let server = selectedServer,
           let userToken = authService.authToken {
            let shuffleEnabled = isShuffleEnabled
            let currentTrackID = currentTrack?.id

            Task {
                await updateServerManagedShuffle(
                    enabled: shuffleEnabled,
                    server: server,
                    userToken: userToken,
                    playQueue: activeServerPlayQueue,
                    keepingTrackID: currentTrackID
                )
            }
            return
        }

        if case let .album(album, library) = activePlaybackSource,
           isShuffleEnabled,
           orderedPlaybackQueue.count >= 20,
           let server = selectedServer,
           let userToken = authService.authToken,
           let currentTrackRatingKey = currentTrack?.ratingKey {
            Task {
                await adoptServerQueueForAlbumShuffle(
                    album: album,
                    library: library,
                    server: server,
                    userToken: userToken,
                    currentTrackRatingKey: currentTrackRatingKey,
                    keepingTrackID: currentTrack?.id
                )
            }
            return
        }

        guard !orderedPlaybackQueue.isEmpty else { return }

        let currentTrackID = currentTrack?.id
        applyPlaybackOrder(keepingTrackID: currentTrackID)
        logDebug(isShuffleEnabled ? "Shuffle enabled" : "Shuffle disabled")
    }

    func setLoudnessLevelingEnabled(_ isEnabled: Bool) {
        guard settingsStore.settings.loudnessLevelingEnabled != isEnabled else { return }

        settingsStore.settings.loudnessLevelingEnabled = isEnabled
        logDebug(isEnabled ? "Loudness leveling enabled" : "Loudness leveling disabled")

        guard let currentTrack else { return }

        Task {
            await applyPlaybackVolume(for: currentTrack)
        }
    }

    func setListenedThresholdPercentage(_ percentage: Int) {
        settingsStore.settings.listenedThresholdPercentage = min(max(percentage, 50), 100)
        markTrackedTrackListenedIfNeeded()
    }

    func setThemePreference(_ preference: AppThemePreference) {
        settingsStore.settings.themePreference = preference
    }

    func beginPlexLogin() {
        Task {
            await authService.beginLogin()
            await reloadPlexData()
        }
    }

    func signOut() {
        stopTrackingCurrentTrack()
        authService.signOut()
        settingsStore.settings.selectedServerID = nil
        settingsStore.settings.selectedLibraryID = nil

        availableServers = []
        availableLibraries = []
        recentlyPlayedAlbums = []
        recentlyAddedAlbums = []
        playlists = []
        stations = []
        orderedPlaybackQueue = []
        playbackQueue = []
        usesServerManagedQueueOrder = false
        activePlaybackSource = nil
        currentQueueIndex = 0
        activeServerPlayQueue = nil
        visiblePlayQueue = []
        relatedAlbums = []
        relatedAlbumsTask?.cancel()
        relatedAlbumsTask = nil
        relatedAlbumsRatingKey = nil
        isQueueOperationInProgress = false
        nowPlaying = .placeholder
        libraryLoadError = nil
        currentLoadingMessage = nil
        playbackState = .stopped
        isPlaybackRequested = false
        playbackPosition = 0
        playbackDuration = 0

        player?.pause()
        removeTimeObserver()
        player = nil
        playerItemEndObserver = nil
        playerTimeControlStatusObserver = nil
        loudnessGainCache.removeAll()
        missingLoudnessAnalysisTrackIDs.removeAll()
    }

    func refreshLibraryContent() {
        Task {
            await refreshCurrentSelection()
        }
    }

    func dismissLibraryLoadError() {
        libraryLoadError = nil
    }

    func didPresentInitialLoadFailure() {
        shouldPresentInitialLoadFailure = false
    }

    func selectServer(id: String) {
        guard settingsStore.settings.selectedServerID != id else { return }

        settingsStore.settings.selectedServerID = id
        settingsStore.settings.selectedLibraryID = nil
        availableLibraries = []

        Task {
            await reloadLibrariesAndContentForSelectedServer(id: id)
        }
    }

    func selectLibrary(id: String) {
        guard settingsStore.settings.selectedLibraryID != id else { return }

        settingsStore.settings.selectedLibraryID = id

        Task {
            await reloadHomeContentForSelection()
        }
    }

    func playAlbum(_ album: PlexAlbum) {
        Task {
            await playAlbumSelection(album)
        }
    }

    private func playAlbumSelection(_ album: PlexAlbum) async {
        guard let library = selectedLibrary else { return }
        activePlaybackSource = .album(album, library)

        await playSelection(named: album.title) {
            guard let server = self.selectedServer,
                  let userToken = self.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            let tracks = try await self.apiClient.fetchAlbumTracks(server: server, album: album, userToken: userToken)
            guard let startingTrackRatingKey = tracks.first?.ratingKey else {
                return tracks
            }

            return try await self.playAlbumUsingServerQueue(
                album: album,
                server: server,
                library: library,
                userToken: userToken,
                fallbackTracks: tracks,
                startingTrackRatingKey: startingTrackRatingKey
            )
        }
    }

    private func playAlbumUsingServerQueue(
        album: PlexAlbum,
        server: PlexServer,
        library: PlexMusicLibrary,
        userToken: String,
        fallbackTracks: [PlexTrack],
        startingTrackRatingKey: String
    ) async throws -> [PlexTrack] {
        do {
            let snapshot = try await apiClient.createAlbumPlayQueue(
                server: server,
                library: library,
                album: album,
                startingTrackRatingKey: startingTrackRatingKey,
                userToken: userToken,
                shuffle: isShuffleEnabled
            )

            adoptServerPlayQueue(snapshot, keepingTrackID: snapshot.selectedTrackID ?? snapshot.tracks.first?.id)
            logDebug("Loaded \(snapshot.tracks.count) track(s) from Plex album play queue")
            await playCurrentTrack()
            logDebug("Now playing \(nowPlaying.trackName)")
            throw AlbumServerQueuePlaybackHandled()
        } catch is AlbumServerQueuePlaybackHandled {
            throw AlbumServerQueuePlaybackHandled()
        } catch {
            logDebug("Album server queue fallback: \(error.localizedDescription)")
            activeServerPlayQueue = nil
            return fallbackTracks
        }
    }

    private struct AlbumServerQueuePlaybackHandled: Error {}

    func playPlaylist(_ playlist: PlexPlaylist) {
        Task {
            self.activePlaybackSource = .playlist(playlist)
            await playServerQueueSelection(named: playlist.title) {
                guard let server = self.selectedServer,
                      let userToken = self.authService.authToken else {
                    throw PlexAPIError.noReachableServer
                }

                return try await self.apiClient.createPlaylistPlayQueue(
                    server: server,
                    playlist: playlist,
                    userToken: userToken,
                    shuffle: self.isShuffleEnabled
                )
            }
        }
    }

    func playStation(_ station: PlexStation) {
        Task {
            self.activePlaybackSource = .station(station)
            await playServerQueueSelection(named: station.title) {
                guard let server = self.selectedServer,
                      let userToken = self.authService.authToken else {
                    throw PlexAPIError.noReachableServer
                }

                return try await self.apiClient.createStationPlayQueue(
                    server: server,
                    station: station,
                    userToken: userToken
                )
            }
        }
    }

    func enqueueAlbum(_ album: PlexAlbum, playNext: Bool) {
        guard let library = selectedLibrary else { return }
        enqueue(fallback: { self.playAlbum(album) }) { server, playQueue, userToken in
            try await self.apiClient.addAlbumToPlayQueue(
                server: server,
                library: library,
                album: album,
                playQueueID: playQueue.id,
                playNext: playNext,
                userToken: userToken
            )
        }
    }

    func enqueuePlaylist(_ playlist: PlexPlaylist, playNext: Bool) {
        enqueue(fallback: { self.playPlaylist(playlist) }) { server, playQueue, userToken in
            try await self.apiClient.addPlaylistToPlayQueue(
                server: server,
                playlist: playlist,
                playQueueID: playQueue.id,
                playNext: playNext,
                userToken: userToken
            )
        }
    }

    func enqueueStation(_ station: PlexStation, playNext: Bool) {
        enqueue(fallback: { self.playStation(station) }) { server, playQueue, userToken in
            try await self.apiClient.addStationToPlayQueue(
                server: server,
                station: station,
                playQueueID: playQueue.id,
                playNext: playNext,
                userToken: userToken
            )
        }
    }

    func refreshPlayQueue() {
        guard let playQueue = activeServerPlayQueue else { return }
        performQueueOperation {
            guard let server = self.selectedServer,
                  let userToken = self.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            return try await self.apiClient.refreshPlayQueue(
                server: server,
                playQueueID: playQueue.id,
                itemCount: playQueue.itemCount,
                centeredOn: self.currentTrack?.playQueueItemID,
                userToken: userToken
            )
        }
    }

    func selectPlayQueueTrack(id: String) {
        guard let index = playbackQueue.firstIndex(where: { $0.id == id }),
              index != currentQueueIndex else {
            return
        }

        currentQueueIndex = index
        Task {
            await playCurrentTrack()
            await refreshServerQueueAfterPlaybackAdvance()
        }
    }

    func removePlayQueueTrack(id: String) {
        guard id != currentTrack?.id,
              let playQueueItemID = playbackQueue.first(where: { $0.id == id })?.playQueueItemID else {
            return
        }

        performQueueOperation {
            guard let playQueue = self.activeServerPlayQueue,
                  let server = self.selectedServer,
                  let userToken = self.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            return try await self.apiClient.removePlayQueueItem(
                server: server,
                playQueueID: playQueue.id,
                playQueueItemID: playQueueItemID,
                itemCount: playQueue.itemCount,
                userToken: userToken
            )
        }
    }

    func movePlayQueueTrack(id: String, before targetID: String) {
        guard id != targetID,
              let playQueue = activeServerPlayQueue,
              let source = playbackQueue.first(where: { $0.id == id }),
              let sourceItemID = source.playQueueItemID,
              let currentIndex = playbackQueue.firstIndex(where: { $0.id == currentTrack?.id }),
              let sourceIndex = playbackQueue.firstIndex(where: { $0.id == id }),
              let targetIndex = playbackQueue.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        guard sourceIndex > currentIndex, targetIndex > currentIndex else { return }

        let precedingTracks = playbackQueue[..<targetIndex].filter { $0.id != id }
        let afterItemID = precedingTracks.last?.playQueueItemID

        performQueueOperation {
            guard let server = self.selectedServer,
                  let userToken = self.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            return try await self.apiClient.movePlayQueueItem(
                server: server,
                playQueueID: playQueue.id,
                playQueueItemID: sourceItemID,
                afterPlayQueueItemID: afterItemID,
                itemCount: playQueue.itemCount,
                userToken: userToken
            )
        }
    }

    func clearUpcomingPlayQueueTracks() {
        guard let currentTrack,
              let currentIndex = playbackQueue.firstIndex(where: { $0.id == currentTrack.id }),
              let server = selectedServer,
              let userToken = authService.authToken,
              let playQueue = activeServerPlayQueue else {
            return
        }

        guard currentIndex < playbackQueue.count - 1 else { return }
        guard !isQueueOperationInProgress else { return }

        let previousOrderedPlaybackQueue = orderedPlaybackQueue
        let previousPlaybackQueue = playbackQueue
        let previousVisiblePlayQueue = visiblePlayQueue
        let previousUsesServerManagedQueueOrder = usesServerManagedQueueOrder
        let previousCurrentQueueIndex = currentQueueIndex
        let previousActiveServerPlayQueue = activeServerPlayQueue
        let previousIsShuffleEnabled = isShuffleEnabled
        let retainedTracks = Array(playbackQueue.prefix(currentIndex + 1))
        let retainedVisibleTracks: [PlexTrack]
        if let visibleCurrentIndex = visiblePlayQueue.firstIndex(where: { $0.id == currentTrack.id }) {
            retainedVisibleTracks = Array(visiblePlayQueue.prefix(visibleCurrentIndex + 1))
        } else {
            retainedVisibleTracks = [currentTrack]
        }

        orderedPlaybackQueue = retainedTracks
        playbackQueue = retainedTracks
        visiblePlayQueue = retainedVisibleTracks
        usesServerManagedQueueOrder = false
        currentQueueIndex = retainedTracks.count - 1
        activeServerPlayQueue = nil
        isShuffleEnabled = false
        isQueueOperationInProgress = true
        Task {
            do {
                try await self.apiClient.clearPlayQueue(
                    server: server,
                    playQueueID: playQueue.id,
                    userToken: userToken
                )
                self.logDebug("Cleared server play queue")
            } catch {
                self.orderedPlaybackQueue = previousOrderedPlaybackQueue
                self.playbackQueue = previousPlaybackQueue
                self.visiblePlayQueue = previousVisiblePlayQueue
                self.usesServerManagedQueueOrder = previousUsesServerManagedQueueOrder
                self.currentQueueIndex = previousCurrentQueueIndex
                self.activeServerPlayQueue = previousActiveServerPlayQueue
                self.isShuffleEnabled = previousIsShuffleEnabled
                self.libraryLoadError = error.localizedDescription
                self.logDebug("Clear upcoming failed: \(error.localizedDescription)")
            }
            self.isQueueOperationInProgress = false
        }
    }

    private func reloadPlexData() async {
        guard let userToken = authService.authToken else { return }

        startDebugLog("Reloading Plex data")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching Plex servers")
            let servers = try await apiClient.fetchServers(userToken: userToken)
            availableServers = servers
            logDebug("Found \(servers.count) server(s)")

            guard let server = resolveServer(from: servers) else {
                settingsStore.settings.selectedServerID = nil
                settingsStore.settings.selectedLibraryID = nil
                availableLibraries = []
                throw PlexAPIError.serverSelectionRequired
            }

            settingsStore.settings.selectedServerID = server.id
            logDebug("Using server: \(server.name)")

            logDebug("Fetching music libraries")
            let libraries = try await apiClient.fetchMusicLibraries(server: server, userToken: userToken)
            availableLibraries = libraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            settingsStore.settings.selectedLibraryID = library.id
            logDebug("Using library: \(library.title)")

            try await loadLibraryContent(server: server, library: library, userToken: userToken, preserveCurrentPlayback: false)
            logDebug("Library load completed")
        } catch {
            libraryLoadError = error.localizedDescription
            shouldPresentInitialLoadFailure = true
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func reloadLibrariesAndContentForSelectedServer(id: String) async {
        guard let userToken = authService.authToken,
              let selectedServer = availableServers.first(where: { $0.id == id }) else {
            return
        }

        startDebugLog("Switching server")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching libraries for \(selectedServer.name)")
            let libraries = try await apiClient.fetchMusicLibraries(server: selectedServer, userToken: userToken)
            guard selectedServerID == selectedServer.id else { return }

            availableLibraries = libraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            settingsStore.settings.selectedLibraryID = library.id
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: selectedServer, library: library, userToken: userToken, preserveCurrentPlayback: false)
            logDebug("Server switch completed")
        } catch {
            libraryLoadError = error.localizedDescription
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func reloadHomeContentForSelection() async {
        guard let userToken = authService.authToken,
              let server = selectedServer,
              let library = selectedLibrary else {
            return
        }

        startDebugLog("Switching library")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Using server: \(server.name)")
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: server, library: library, userToken: userToken, preserveCurrentPlayback: false)
            logDebug("Library switch completed")
        } catch {
            libraryLoadError = error.localizedDescription
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func refreshCurrentSelection() async {
        guard let userToken = authService.authToken else { return }

        startDebugLog("Refreshing current library")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching Plex servers")
            let servers = try await apiClient.fetchServers(userToken: userToken)
            availableServers = servers
            logDebug("Found \(servers.count) server(s)")

            guard let server = resolveServer(from: servers) else {
                settingsStore.settings.selectedServerID = nil
                settingsStore.settings.selectedLibraryID = nil
                availableLibraries = []
                throw PlexAPIError.serverSelectionRequired
            }

            settingsStore.settings.selectedServerID = server.id
            logDebug("Using server: \(server.name)")

            logDebug("Fetching music libraries")
            let libraries = try await apiClient.fetchMusicLibraries(server: server, userToken: userToken)
            availableLibraries = libraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            settingsStore.settings.selectedLibraryID = library.id
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: server, library: library, userToken: userToken, preserveCurrentPlayback: true)
            logDebug("Refresh completed")
        } catch {
            libraryLoadError = error.localizedDescription
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func loadLibraryContent(server: PlexServer, library: PlexMusicLibrary, userToken: String, preserveCurrentPlayback: Bool) async throws {
        logDebug("Fetching home content")
        try await reloadHomeContent(server: server, library: library, userToken: userToken)

        if preserveCurrentPlayback,
           selectedServerID == server.id,
           selectedLibraryID == library.id,
           currentTrack != nil {
            logDebug("Preserving current playback for refresh")
            return
        }

        logDebug("Fetching last played track")
        await prepareLastPlayedTrack(server: server, library: library, userToken: userToken)
    }

    private func reloadHomeContent(server: PlexServer, library: PlexMusicLibrary, userToken: String) async throws {
        let homeContent = try await apiClient.fetchHomeContent(
            server: server,
            library: library,
            userToken: userToken,
            limit: homeFetchLimit
        )

        recentlyPlayedAlbums = homeContent.recentlyPlayedAlbums
        recentlyAddedAlbums = homeContent.recentlyAddedAlbums
        playlists = homeContent.playlists
        stations = homeContent.stations
        logDebug("Loaded \(recentlyPlayedAlbums.count) recent played, \(recentlyAddedAlbums.count) recent added, \(playlists.count) playlists, \(stations.count) stations")
    }

    private func prepareLastPlayedTrack(server: PlexServer, library: PlexMusicLibrary, userToken: String) async {
        resetPlaybackPreview()

        do {
            guard let lastPlayedTrack = try await apiClient.fetchLastPlayedTrack(server: server, library: library, userToken: userToken) else {
                logDebug("No last played track found")
                return
            }

            updateNowPlaying(from: lastPlayedTrack)
            await preparePlayer(for: lastPlayedTrack)
            isPlaybackRequested = false
            playbackState = .paused

            logDebug("Prepared last played track: \(lastPlayedTrack.title)")
        } catch {
            logDebug("Last played track lookup failed: \(error.localizedDescription)")
        }
    }

    private func resetPlaybackPreview() {
        stopTrackingCurrentTrack()
        orderedPlaybackQueue = []
        playbackQueue = []
        visiblePlayQueue = []
        relatedAlbums = []
        relatedAlbumsTask?.cancel()
        relatedAlbumsTask = nil
        relatedAlbumsRatingKey = nil
        usesServerManagedQueueOrder = false
        activePlaybackSource = nil
        activeServerPlayQueue = nil
        currentQueueIndex = 0
        nowPlaying = .placeholder
        isPlaybackRequested = false
        playbackState = .stopped
        playbackPosition = 0
        playbackDuration = 0
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    private func playCurrentTrack() async {
        guard let track = currentTrack else { return }
        updateNowPlaying(from: track)
        isPlaybackRequested = true
        playbackState = .buffering
        await preparePlayer(for: track)
        guard currentTrack?.id == track.id else { return }
        reportTrackedPlaybackTimeline(state: .buffering)
        player?.play()
        synchronizePlaybackState(with: player?.timeControlStatus ?? .waitingToPlayAtSpecifiedRate)
    }

    private func playSelection(named name: String, loader: @escaping () async throws -> [PlexTrack]) async {
        isLoadingLibrary = true
        libraryLoadError = nil
        startDebugLog("Starting playback for \(name)")

        do {
            let tracks = try await loader()
            activeServerPlayQueue = nil
            replacePlaybackQueue(with: tracks, keepingTrackID: tracks.first?.id)
            logDebug("Loaded \(tracks.count) track(s) for playback")
            await playCurrentTrack()
            logDebug("Now playing \(nowPlaying.trackName)")
        } catch is AlbumServerQueuePlaybackHandled {
        } catch {
            libraryLoadError = error.localizedDescription
            logDebug("Playback load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
    }

    private func playServerQueueSelection(named name: String, loader: @escaping () async throws -> PlexPlayQueueSnapshot) async {
        isLoadingLibrary = true
        libraryLoadError = nil
        startDebugLog("Starting playback for \(name)")

        do {
            let snapshot = try await loader()
            adoptServerPlayQueue(snapshot, keepingTrackID: snapshot.selectedTrackID ?? snapshot.tracks.first?.id)
            logDebug("Loaded \(snapshot.tracks.count) track(s) from Plex play queue")
            await playCurrentTrack()
            logDebug("Now playing \(nowPlaying.trackName)")
        } catch {
            libraryLoadError = error.localizedDescription
            logDebug("Playback load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
    }

    private func preparePlayer(for track: PlexTrack) async {
        let preparationID = nextPlaybackPreparationID()
        let item = AVPlayerItem(url: track.streamURL)
        let volume = await resolvePlaybackVolume(for: track)

        guard preparationID == playbackPreparationID else { return }

        invalidatePendingSeek()
        beginTracking(track)
        observePlaybackEnd(for: item)

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

    private func updateNowPlaying(from track: PlexTrack) {
        nowPlaying = TrackMetadata(
            trackName: track.title,
            trackArtist: track.trackArtist,
            albumArtist: track.albumArtist,
            albumName: track.albumName,
            artworkURL: track.artworkURL,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber
        )
        refreshRelatedAlbums(for: track)
    }

    private func refreshRelatedAlbums(for track: PlexTrack) {
        guard relatedAlbumsRatingKey != track.albumRatingKey || relatedAlbums.isEmpty else { return }

        relatedAlbumsTask?.cancel()
        relatedAlbums = []
        relatedAlbumsRatingKey = track.albumRatingKey

        guard let albumRatingKey = track.albumRatingKey,
              let server = selectedServer,
              let userToken = authService.authToken else {
            return
        }

        relatedAlbumsTask = Task {
            do {
                let albums = try await apiClient.fetchRelatedAlbums(
                    server: server,
                    albumRatingKey: albumRatingKey,
                    userToken: userToken
                )
                guard !Task.isCancelled, currentTrack?.id == track.id else { return }
                relatedAlbums = albums
            } catch {
                guard !Task.isCancelled else { return }
                logDebug("Related albums lookup failed: \(error.localizedDescription)")
            }
        }
    }

    private var currentTrack: PlexTrack? {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return nil }
        return playbackQueue[currentQueueIndex]
    }

    private func replacePlaybackQueue(with tracks: [PlexTrack], keepingTrackID: String?, usesServerOrder: Bool = false) {
        orderedPlaybackQueue = tracks
        usesServerManagedQueueOrder = usesServerOrder
        visiblePlayQueue = usesServerOrder ? tracks : []
        applyPlaybackOrder(keepingTrackID: keepingTrackID)
    }

    private func adoptServerPlayQueue(_ snapshot: PlexPlayQueueSnapshot, keepingTrackID: String?) {
        activeServerPlayQueue = ServerPlayQueueContext(id: snapshot.id, itemCount: max(snapshot.totalCount, snapshot.tracks.count))
        isShuffleEnabled = snapshot.isShuffled
        replacePlaybackQueue(
            with: snapshot.tracks,
            keepingTrackID: keepingTrackID,
            usesServerOrder: true
        )

        if let currentTrack {
            updateNowPlaying(from: currentTrack)
        }
    }

    private func enqueue(
        fallback: @escaping () -> Void,
        loader: @escaping (PlexServer, ServerPlayQueueContext, String) async throws -> PlexPlayQueueSnapshot
    ) {
        guard let playQueue = activeServerPlayQueue else {
            fallback()
            return
        }

        performQueueOperation {
            guard let server = self.selectedServer,
                  let userToken = self.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            return try await loader(server, playQueue, userToken)
        }
    }

    private func performQueueOperation(loader: @escaping () async throws -> PlexPlayQueueSnapshot) {
        guard !isQueueOperationInProgress else { return }

        isQueueOperationInProgress = true
        let keepingTrackID = currentTrack?.id
        Task {
            do {
                let snapshot = try await loader()
                self.adoptServerPlayQueue(snapshot, keepingTrackID: keepingTrackID ?? snapshot.selectedTrackID)
            } catch {
                self.libraryLoadError = error.localizedDescription
                self.logDebug("Queue update failed: \(error.localizedDescription)")
            }
            self.isQueueOperationInProgress = false
        }
    }

    private func refreshServerQueueAfterPlaybackAdvance() async {
        guard let playQueue = activeServerPlayQueue,
              let server = selectedServer,
              let userToken = authService.authToken else {
            return
        }

        let keepingTrackID = currentTrack?.id
        let centerItemID = currentTrack?.playQueueItemID
        try? await Task.sleep(for: .milliseconds(300))

        do {
            let snapshot = try await apiClient.refreshPlayQueue(
                server: server,
                playQueueID: playQueue.id,
                itemCount: playQueue.itemCount,
                centeredOn: centerItemID,
                userToken: userToken
            )
            adoptServerPlayQueue(snapshot, keepingTrackID: keepingTrackID ?? snapshot.selectedTrackID)
        } catch {
            logDebug("Queue refresh after track change failed: \(error.localizedDescription)")
        }
    }

    private func applyPlaybackOrder(keepingTrackID: String?) {
        guard !orderedPlaybackQueue.isEmpty else {
            playbackQueue = []
            currentQueueIndex = 0
            playbackState = .stopped
            return
        }

        if usesServerManagedQueueOrder {
            playbackQueue = orderedPlaybackQueue
        } else if isShuffleEnabled {
            playbackQueue = shuffledQueue(from: orderedPlaybackQueue, keepingTrackID: keepingTrackID)
        } else {
            playbackQueue = orderedPlaybackQueue
        }

        if let keepingTrackID,
           let queueIndex = playbackQueue.firstIndex(where: { $0.id == keepingTrackID }) {
            currentQueueIndex = queueIndex
        } else {
            currentQueueIndex = 0
        }
    }

    private func shuffledQueue(from tracks: [PlexTrack], keepingTrackID: String?) -> [PlexTrack] {
        guard let keepingTrackID,
              let currentTrack = tracks.first(where: { $0.id == keepingTrackID }) else {
            return tracks.shuffled()
        }

        let remainingTracks = tracks.filter { $0.id != keepingTrackID }.shuffled()
        return [currentTrack] + remainingTracks
    }

    private func observePlaybackEnd(for item: AVPlayerItem) {
        playerItemEndObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.handlePlaybackEnded()
                }
            }
    }

    private func observePlaybackTime() {
        guard let player, timeObserverToken == nil else { return }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }

            Task { @MainActor in
                let seconds = time.seconds
                if seconds.isFinite, self.pendingSeekProgress == nil {
                    self.playbackPosition = max(0, seconds)
                }

                if let duration = player.currentItem?.duration.seconds,
                   duration.isFinite,
                   duration > 0 {
                    self.playbackDuration = duration
                }

                self.reportTrackedPlaybackTimelineIfNeeded()
                self.markTrackedTrackListenedIfNeeded()
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
        } else if let durationMilliseconds = trackedTrack?.durationMilliseconds {
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

    private func handlePlaybackEnded() async {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return }

        markTrackedTrackListenedIfNeeded(force: true)
        stopTrackingCurrentTrack()

        if currentQueueIndex < playbackQueue.count - 1 {
            currentQueueIndex += 1
            await playCurrentTrack()
            await refreshServerQueueAfterPlaybackAdvance()
            logDebug("Auto-advanced to \(nowPlaying.trackName)")
            return
        }

        playbackPosition = 0
        await player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        isPlaybackRequested = false
        transitionPlaybackState(to: .paused)
        logDebug("Reached end of queue")
    }

    private func synchronizePlaybackState(with timeControlStatus: AVPlayer.TimeControlStatus) {
        switch timeControlStatus {
        case .paused:
            transitionPlaybackState(to: isPlaybackRequested ? .buffering : .paused)
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
        reportTrackedPlaybackTimeline(state: newState)
    }

    private func beginTracking(_ track: PlexTrack) {
        guard trackedTrack?.id != track.id else { return }

        stopTrackingCurrentTrack()
        trackedTrack = track
        hasMarkedTrackedTrackListened = false
        lastTimelineReportDate = nil
    }

    private func stopTrackingCurrentTrack() {
        guard trackedTrack != nil else { return }
        reportTrackedPlaybackTimeline(state: .stopped)
        trackedTrack = nil
        hasMarkedTrackedTrackListened = false
        lastTimelineReportDate = nil
    }

    private func reportTrackedPlaybackTimelineIfNeeded() {
        guard playbackState == .playing else { return }

        if let lastTimelineReportDate,
           Date().timeIntervalSince(lastTimelineReportDate) < timelineReportInterval {
            return
        }

        reportTrackedPlaybackTimeline(state: .playing)
    }

    private func reportTrackedPlaybackTimeline(state: PlaybackState) {
        guard let track = trackedTrack,
              let ratingKey = track.ratingKey,
              let server = selectedServer,
              let userToken = authService.authToken else {
            return
        }

        let positionMilliseconds = Int((playbackPosition * 1_000).rounded())
        let durationMilliseconds = resolvedDurationMilliseconds(for: track)
        let playQueue = activeServerPlayQueue
        lastTimelineReportDate = Date()

        let previousTimelineReportTask = timelineReportTask
        timelineReportTask = Task {
            await previousTimelineReportTask?.value

            do {
                try await apiClient.reportPlaybackTimeline(
                    server: server,
                    ratingKey: ratingKey,
                    playQueueID: playQueue?.id,
                    playQueueItemID: track.playQueueItemID,
                    state: state,
                    positionMilliseconds: positionMilliseconds,
                    durationMilliseconds: durationMilliseconds,
                    userToken: userToken
                )
            } catch {
                logDebug("Timeline update failed for \(track.title): \(error.localizedDescription)")
            }
        }
    }

    private func markTrackedTrackListenedIfNeeded(force: Bool = false) {
        guard !hasMarkedTrackedTrackListened,
              let track = trackedTrack,
              let ratingKey = track.ratingKey,
              let server = selectedServer,
              let userToken = authService.authToken else {
            return
        }

        let durationMilliseconds = resolvedDurationMilliseconds(for: track)
        guard durationMilliseconds > 0 else { return }

        let listenedPercentage = (playbackPosition * 1_000 / Double(durationMilliseconds)) * 100
        guard force || listenedPercentage >= Double(listenedThresholdPercentage) else { return }

        hasMarkedTrackedTrackListened = true
        Task {
            do {
                try await apiClient.markTrackListened(server: server, ratingKey: ratingKey, userToken: userToken)
                logDebug("Marked \(track.title) listened at \(Int(listenedPercentage.rounded()))%")
            } catch {
                if trackedTrack?.id == track.id {
                    hasMarkedTrackedTrackListened = false
                }
                logDebug("Listened update failed for \(track.title): \(error.localizedDescription)")
            }
        }
    }

    private func resolvedDurationMilliseconds(for track: PlexTrack) -> Int {
        if trackedTrack?.id == track.id, playbackDuration.isFinite, playbackDuration > 0 {
            return Int((playbackDuration * 1_000).rounded())
        }

        return track.durationMilliseconds ?? 0
    }

    private func nextPlaybackPreparationID() -> Int {
        playbackPreparationID += 1
        return playbackPreparationID
    }

    private func nextSeekID() -> Int {
        seekID += 1
        return seekID
    }

    private func invalidatePendingSeek() {
        seekID += 1
        pendingSeekProgress = nil
    }

    private func updateServerManagedShuffle(enabled: Bool, server: PlexServer, userToken: String, playQueue: ServerPlayQueueContext, keepingTrackID: String?) async {
        do {
            let snapshot = try await {
                if enabled {
                    return try await apiClient.shufflePlayQueue(
                        server: server,
                        playQueueID: playQueue.id,
                        itemCount: playQueue.itemCount,
                        userToken: userToken
                    )
                }

                return try await apiClient.unshufflePlayQueue(
                    server: server,
                    playQueueID: playQueue.id,
                    itemCount: playQueue.itemCount,
                    userToken: userToken
                )
            }()

            adoptServerPlayQueue(snapshot, keepingTrackID: snapshot.selectedTrackID ?? keepingTrackID)

            logDebug(enabled ? "Shuffle enabled" : "Shuffle disabled")
        } catch {
            isShuffleEnabled.toggle()
            libraryLoadError = error.localizedDescription
            logDebug("Shuffle update failed: \(error.localizedDescription)")
        }
    }

    private func adoptServerQueueForAlbumShuffle(
        album: PlexAlbum,
        library: PlexMusicLibrary,
        server: PlexServer,
        userToken: String,
        currentTrackRatingKey: String,
        keepingTrackID: String?
    ) async {
        do {
            let snapshot = try await apiClient.createAlbumPlayQueue(
                server: server,
                library: library,
                album: album,
                startingTrackRatingKey: currentTrackRatingKey,
                userToken: userToken,
                shuffle: true
            )

            adoptServerPlayQueue(snapshot, keepingTrackID: snapshot.selectedTrackID ?? keepingTrackID)

            logDebug("Shuffle enabled")
        } catch {
            isShuffleEnabled.toggle()
            libraryLoadError = error.localizedDescription
            logDebug("Shuffle update failed: \(error.localizedDescription)")
        }
    }

    private func applyPlaybackVolume(for track: PlexTrack) async {
        let volume = await resolvePlaybackVolume(for: track)
        guard currentTrack?.id == track.id else { return }
        player?.volume = volume
    }

    private func resolvePlaybackVolume(for track: PlexTrack) async -> Float {
        guard settingsStore.settings.loudnessLevelingEnabled else {
            logDebug("Loudness leveling disabled for \(track.title)")
            return 1.0
        }

        logDebug("Loudness leveling enabled for \(track.title)")

        guard let server = selectedServer,
              let userToken = authService.authToken else {
            logDebug("Skipping loudness leveling for \(track.title): missing Plex identifiers")
            return 1.0
        }

        let ratingKey = track.ratingKey ?? track.id

        if let cachedGain = loudnessGainCache[ratingKey] {
            let volume = volumeScalar(for: cachedGain)
            logDebug("Applied cached loudness gain \(formatted(decibels: cachedGain)) dB to \(track.title)")
            return volume
        }

        if missingLoudnessAnalysisTrackIDs.contains(ratingKey) {
            logDebug("No loudness analysis found for \(track.title)")
            return 1.0
        }

        do {
            guard let gain = try await apiClient.fetchLoudnessGain(server: server, ratingKey: ratingKey, userToken: userToken) else {
                missingLoudnessAnalysisTrackIDs.insert(ratingKey)
                logDebug("No loudness analysis found for \(track.title)")
                return 1.0
            }

            loudnessGainCache[ratingKey] = gain
            let volume = volumeScalar(for: gain)

            if volume < 1.0 {
                logDebug("Applied loudness gain \(formatted(decibels: gain)) dB to \(track.title)")
            } else {
                logDebug("Found loudness gain \(formatted(decibels: gain)) dB for \(track.title), using unity volume")
            }

            return volume
        } catch {
            logDebug("Skipped loudness leveling for \(track.title): \(error.localizedDescription)")
            return 1.0
        }
    }

    private func volumeScalar(for gainInDecibels: Float) -> Float {
        guard gainInDecibels < 0 else {
            return 1.0
        }

        return max(0.05, min(1.0, pow(10, gainInDecibels / 20)))
    }

    private func formatted(decibels: Float) -> String {
        String(format: "%.2f", decibels)
    }

    private var selectedServer: PlexServer? {
        if let selectedID = settingsStore.settings.selectedServerID,
           let server = availableServers.first(where: { $0.id == selectedID }) {
            return server
        }

        return nil
    }

    private var selectedLibrary: PlexMusicLibrary? {
        guard !availableLibraries.isEmpty else { return nil }

        if let selectedID = settingsStore.settings.selectedLibraryID,
           let library = availableLibraries.first(where: { $0.id == selectedID }) {
            return library
        }

        return availableLibraries.first
    }

    private func resolveServer(from servers: [PlexServer]) -> PlexServer? {
        if let selectedID = settingsStore.settings.selectedServerID,
           let server = servers.first(where: { $0.id == selectedID }) {
            return server
        }

        return nil
    }

    private func resolveLibrary(from libraries: [PlexMusicLibrary]) -> PlexMusicLibrary? {
        if let selectedID = settingsStore.settings.selectedLibraryID,
           let library = libraries.first(where: { $0.id == selectedID }) {
            return library
        }

        return libraries.first
    }

    private func bindChildObjects() {
        authService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settingsStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func startDebugLog(_ message: String) {
        currentLoadingMessage = stripDebugTimestamp(from: message)
        logDebug(message)
    }

    private func logDebug(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
    }

    private func stripDebugTimestamp(from line: String) -> String {
        guard let closingBracketIndex = line.firstIndex(of: "]") else {
            return line
        }

        return line[line.index(after: closingBracketIndex)...].trimmingCharacters(in: .whitespaces)
    }
}
