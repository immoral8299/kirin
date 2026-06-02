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
    @Published var isLoadingLibrary = false
    @Published var libraryLoadError: String?
    @Published var availableServers: [PlexServer] = []
    @Published var availableLibraries: [PlexMusicLibrary] = []
    @Published var currentLoadingMessage: String?

    let settingsStore = SettingsStore()
    let authService = PlexAuthService()

    private let apiClient = PlexAPIClient()
    private let homeFetchLimit = 12
    private var cancellables = Set<AnyCancellable>()

    private var orderedPlaybackQueue: [PlexTrack] = []
    private var playbackQueue: [PlexTrack] = []
    private var usesServerManagedQueueOrder = false
    private var currentQueueIndex: Int = 0
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playerItemEndObserver: AnyCancellable?
    private var preferredQueueTrackID: String?
    private var playbackPreparationID: Int = 0
    private var loudnessGainCache: [String: Float] = [:]
    private var missingLoudnessAnalysisTrackIDs = Set<String>()
    private var activeServerPlayQueue: ServerPlayQueueContext?

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

        return settingsStore.settings.menuBarFormat.render(with: nowPlaying)
    }

    var statusIconName: String {
        if !shouldPreserveNowPlayingStatus,
           isShowingTransientStatus {
            return playbackState == .playing ? PlaybackState.buffering.systemImageName : playbackState.systemImageName
        }

        return playbackState.systemImageName
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
        playbackState == .playing && nowPlaying != .placeholder
    }

    var isAuthenticated: Bool {
        authService.authToken != nil
    }

    var isLoudnessLevelingEnabled: Bool {
        settingsStore.settings.loudnessLevelingEnabled
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
        !recentlyPlayedAlbums.isEmpty || !recentlyAddedAlbums.isEmpty || !playlists.isEmpty
    }

    var loadingTargetDescription: String? {
        guard let serverName = selectedServerName, let libraryTitle = selectedLibraryTitle else {
            return nil
        }

        return "\(serverName) / \(libraryTitle)"
    }

    var shouldOpenSettingsForLibraryError: Bool {
        guard let libraryLoadError else { return false }
        let normalizedError = libraryLoadError.lowercased()
        return normalizedError.contains("timed out") || normalizedError.contains("timeout")
    }

    var playbackProgress: Double {
        if let pendingSeekProgress {
            return pendingSeekProgress
        }

        guard playbackDuration > 0 else { return 0 }
        return min(max(playbackPosition / playbackDuration, 0), 1)
    }

    func togglePlayback() {
        guard let player else { return }

        switch playbackState {
        case .playing:
            player.pause()
            playbackState = .paused
        case .paused, .stopped:
            player.play()
            playbackState = .playing
        case .buffering:
            break
        }
    }

    func nextTrack() {
        guard !playbackQueue.isEmpty else { return }
        let nextIndex = min(currentQueueIndex + 1, playbackQueue.count - 1)
        guard nextIndex != currentQueueIndex else { return }

        currentQueueIndex = nextIndex
        Task {
            await playCurrentTrack()
        }
    }

    func previousTrack() {
        guard !playbackQueue.isEmpty else { return }
        let previousIndex = max(currentQueueIndex - 1, 0)
        guard previousIndex != currentQueueIndex else { return }

        currentQueueIndex = previousIndex
        Task {
            await playCurrentTrack()
        }
    }

    func seekToProgress(_ progress: Double) {
        guard let player, playbackDuration > 0 else { return }

        let clampedProgress = min(max(progress, 0), 1)
        let targetTime = CMTime(seconds: playbackDuration * clampedProgress, preferredTimescale: 600)
        pendingSeekProgress = clampedProgress
        playbackPosition = min(max(targetTime.seconds, 0), playbackDuration)

        Task {
            await player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
            playbackPosition = min(max(targetTime.seconds, 0), playbackDuration)
            pendingSeekProgress = nil
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

    func beginPlexLogin() {
        Task {
            await authService.beginLogin()
            await reloadPlexData()
        }
    }

    func signOut() {
        authService.signOut()
        settingsStore.settings.selectedServerID = nil
        settingsStore.settings.selectedLibraryID = nil

        availableServers = []
        availableLibraries = []
        recentlyPlayedAlbums = []
        recentlyAddedAlbums = []
        playlists = []
        orderedPlaybackQueue = []
        playbackQueue = []
        usesServerManagedQueueOrder = false
        currentQueueIndex = 0
        activeServerPlayQueue = nil
        nowPlaying = .placeholder
        libraryLoadError = nil
        currentLoadingMessage = nil
        playbackState = .stopped
        playbackPosition = 0
        playbackDuration = 0

        player?.pause()
        removeTimeObserver()
        player = nil
        playerItemEndObserver = nil
        loudnessGainCache.removeAll()
        missingLoudnessAnalysisTrackIDs.removeAll()
    }

    func refreshLibraryContent() {
        Task {
            await refreshCurrentSelection()
        }
    }

    func selectServer(id: String) {
        guard settingsStore.settings.selectedServerID != id else { return }

        settingsStore.settings.selectedServerID = id
        settingsStore.settings.selectedLibraryID = nil

        Task {
            await reloadLibrariesAndContentForSelectedServer()
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
        await playSelection(named: album.title) {
            guard let server = self.selectedServer,
                  let library = self.selectedLibrary,
                  let userToken = self.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            let tracks = try await self.apiClient.fetchAlbumTracks(server: server, album: album, userToken: userToken)
            guard self.isShuffleEnabled, tracks.count >= 20 else {
                return tracks
            }

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
                shuffle: true
            )

            activeServerPlayQueue = ServerPlayQueueContext(id: snapshot.id, itemCount: max(snapshot.totalCount, snapshot.tracks.count))
            replacePlaybackQueue(
                with: snapshot.tracks,
                keepingTrackID: snapshot.selectedTrackID ?? snapshot.tracks.first?.id,
                usesServerOrder: true
            )
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
                throw PlexAPIError.noReachableServer
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
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func reloadLibrariesAndContentForSelectedServer() async {
        guard let userToken = authService.authToken,
              let selectedServer = selectedServer else {
            return
        }

        startDebugLog("Switching server")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching libraries for \(selectedServer.name)")
            let libraries = try await apiClient.fetchMusicLibraries(server: selectedServer, userToken: userToken)
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
                throw PlexAPIError.noReachableServer
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
        try await prepareLastPlayedTrack(server: server, library: library, userToken: userToken)
        logDebug("Fetching playback queue")
        try await reloadPlaybackQueue(server: server, library: library, userToken: userToken)
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
        logDebug("Loaded \(recentlyPlayedAlbums.count) recent played, \(recentlyAddedAlbums.count) recent added, \(playlists.count) playlists")
    }

    private func reloadPlaybackQueue(server: PlexServer, library: PlexMusicLibrary, userToken: String) async throws {
        let queue = try await apiClient.fetchPlaybackQueue(server: server, library: library, userToken: userToken)
        logDebug("Loaded playback queue with \(queue.count) track(s)")

        activeServerPlayQueue = nil
        replacePlaybackQueue(with: queue, keepingTrackID: preferredQueueTrackID)
        preferredQueueTrackID = nil

        if let currentTrack {
            updateNowPlaying(from: currentTrack)
            await preparePlayer(for: currentTrack)
            playbackState = .paused
            logDebug("Prepared queue at track: \(currentTrack.title)")
        }
    }

    private func prepareLastPlayedTrack(server: PlexServer, library: PlexMusicLibrary, userToken: String) async throws {
        guard let lastPlayedTrack = try await apiClient.fetchLastPlayedTrack(server: server, library: library, userToken: userToken) else {
            logDebug("No last played track found")
            return
        }

        updateNowPlaying(from: lastPlayedTrack)
        await preparePlayer(for: lastPlayedTrack)
        playbackState = .paused
        preferredQueueTrackID = lastPlayedTrack.id

        logDebug("Prepared last played track: \(lastPlayedTrack.title)")
    }

    private func playCurrentTrack() async {
        guard let track = currentTrack else { return }
        updateNowPlaying(from: track)
        playbackState = .buffering
        await preparePlayer(for: track)
        guard currentTrack?.id == track.id else { return }
        player?.play()
        playbackState = .playing
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
            activeServerPlayQueue = ServerPlayQueueContext(id: snapshot.id, itemCount: max(snapshot.totalCount, snapshot.tracks.count))
            replacePlaybackQueue(
                with: snapshot.tracks,
                keepingTrackID: snapshot.selectedTrackID ?? snapshot.tracks.first?.id,
                usesServerOrder: true
            )
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

        observePlaybackEnd(for: item)

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
        }

        player?.volume = volume
        observePlaybackTime()
        updatePlaybackTiming(from: item)
    }

    private func updateNowPlaying(from track: PlexTrack) {
        nowPlaying = TrackMetadata(
            trackName: track.title,
            trackArtist: track.trackArtist,
            albumArtist: track.albumArtist,
            albumName: track.albumName,
            artworkURL: track.artworkURL
        )
    }

    private var currentTrack: PlexTrack? {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return nil }
        return playbackQueue[currentQueueIndex]
    }

    private func replacePlaybackQueue(with tracks: [PlexTrack], keepingTrackID: String?, usesServerOrder: Bool = false) {
        orderedPlaybackQueue = tracks
        usesServerManagedQueueOrder = usesServerOrder
        applyPlaybackOrder(keepingTrackID: keepingTrackID)
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
                if seconds.isFinite {
                    self.playbackPosition = max(0, seconds)
                }

                if let duration = player.currentItem?.duration.seconds,
                   duration.isFinite,
                   duration > 0 {
                    self.playbackDuration = duration
                }
            }
        }
    }

    private func updatePlaybackTiming(from item: AVPlayerItem) {
        playbackPosition = 0

        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            playbackDuration = duration
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

        if currentQueueIndex < playbackQueue.count - 1 {
            currentQueueIndex += 1
            await playCurrentTrack()
            logDebug("Auto-advanced to \(nowPlaying.trackName)")
            return
        }

        playbackPosition = 0
        await player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        playbackState = .paused
        logDebug("Reached end of queue")
    }

    private func nextPlaybackPreparationID() -> Int {
        playbackPreparationID += 1
        return playbackPreparationID
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

            activeServerPlayQueue = ServerPlayQueueContext(id: snapshot.id, itemCount: max(snapshot.totalCount, snapshot.tracks.count))
            replacePlaybackQueue(
                with: snapshot.tracks,
                keepingTrackID: snapshot.selectedTrackID ?? keepingTrackID,
                usesServerOrder: true
            )

            if let currentTrack {
                updateNowPlaying(from: currentTrack)
            }

            logDebug(enabled ? "Shuffle enabled" : "Shuffle disabled")
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
        guard !availableServers.isEmpty else { return nil }

        if let selectedID = settingsStore.settings.selectedServerID,
           let server = availableServers.first(where: { $0.id == selectedID }) {
            return server
        }

        return availableServers.first
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

        return servers.first
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
        currentLoadingMessage = message
        print(line)
    }

    private func stripDebugTimestamp(from line: String) -> String {
        guard let closingBracketIndex = line.firstIndex(of: "]") else {
            return line
        }

        return line[line.index(after: closingBracketIndex)...].trimmingCharacters(in: .whitespaces)
    }
}
