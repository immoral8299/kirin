import Foundation

@MainActor
final class QueueManager: ObservableObject {
    @Published var visiblePlayQueue: [PlexTrack] = []
    @Published var isQueueOperationInProgress = false
    @Published var isShuffleEnabled = false
    @Published private(set) var pendingPlaybackID: String?
    @Published private(set) var pendingPlaybackSource: String?

    private let context: StoreContext
    private var orderedPlaybackQueue: [PlexTrack] = []
    private var playbackQueue: [PlexTrack] = []
    private var usesServerManagedQueueOrder = false
    private var currentQueueIndex: Int = 0
    private var activePlaybackSource: PlaybackSource?
    private var activeServerPlayQueue: ServerPlayQueueContext?

    private struct ServerPlayQueueContext {
        let id: Int
        let itemCount: Int
    }

    private enum PlaybackSource {
        case album(PlexAlbum, PlexMusicLibrary)
        case playlist(PlexPlaylist)
        case station(PlexStation)
    }

    init(context: StoreContext) {
        self.context = context
    }

    var currentTrack: PlexTrack? {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return nil }
        return playbackQueue[currentQueueIndex]
    }

    var hasEditablePlayQueue: Bool {
        activeServerPlayQueue != nil
    }

    var currentPlayQueueTrackID: String? {
        currentTrack?.id
    }

    var allTracks: [PlexTrack] { playbackQueue }

    // MARK: - Play

    func playAlbum(_ album: PlexAlbum) {
        playAlbum(album, source: nil)
    }

    func playAlbum(_ album: PlexAlbum, source: String?) {
        let pendingID = PendingPlaybackID.album(album.id)
        pendingPlaybackID = pendingID
        pendingPlaybackSource = source
        Task {
            await playAlbumSelection(album)
            clearPendingPlayback(ifMatching: pendingID)
        }
    }

    func playPlaylist(_ playlist: PlexPlaylist) {
        let pendingID = PendingPlaybackID.playlist(playlist.id)
        pendingPlaybackID = pendingID
        Task {
            activePlaybackSource = .playlist(playlist)
            await playServerQueueSelection(named: playlist.title) {
                guard let server = self.context.libraryStore?.selectedServer,
                      let userToken = self.context.plexService!.authService.authToken else {
                    throw PlexAPIError.noReachableServer
                }

                return try await self.context.plexService!.createPlaylistPlayQueue(
                    server: server,
                    playlist: playlist,
                    userToken: userToken,
                    shuffle: self.isShuffleEnabled
                )
            }
            clearPendingPlayback(ifMatching: pendingID)
        }
    }

    func playStation(_ station: PlexStation) {
        let pendingID = PendingPlaybackID.station(station.id)
        pendingPlaybackID = pendingID
        Task {
            activePlaybackSource = .station(station)
            await playServerQueueSelection(named: station.title) {
                guard let server = self.context.libraryStore?.selectedServer,
                      let userToken = self.context.plexService!.authService.authToken else {
                    throw PlexAPIError.noReachableServer
                }

                return try await self.context.plexService!.createStationPlayQueue(
                    server: server,
                    station: station,
                    userToken: userToken
                )
            }
            clearPendingPlayback(ifMatching: pendingID)
        }
    }

    // MARK: - Enqueue

    func enqueueAlbum(_ album: PlexAlbum, playNext: Bool) {
        guard let library = self.context.libraryStore?.selectedLibrary else { return }
        enqueue(fallback: { self.playAlbum(album) }) { server, playQueue, userToken in
            try await self.context.plexService!.addAlbumToPlayQueue(
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
            try await self.context.plexService!.addPlaylistToPlayQueue(
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
            try await self.context.plexService!.addStationToPlayQueue(
                server: server,
                station: station,
                playQueueID: playQueue.id,
                playNext: playNext,
                userToken: userToken
            )
        }
    }

    func playStationRecommendation(_ recommendation: PlexStationRecommendation) {
        switch recommendation.kind {
        case .artist:
            guard let station = recommendation.station else { return }
            let pendingID = PendingPlaybackID.recommendation(recommendation.id)
            pendingPlaybackID = pendingID
            Task {
                activePlaybackSource = .station(station)
                await playServerQueueSelection(named: station.title) {
                    guard let server = self.context.libraryStore?.selectedServer,
                          let userToken = self.context.plexService!.authService.authToken else {
                        throw PlexAPIError.noReachableServer
                    }

                    return try await self.context.plexService!.createStationPlayQueue(
                        server: server,
                        station: station,
                        userToken: userToken
                    )
                }
                clearPendingPlayback(ifMatching: pendingID)
            }
        case .album:
            let pendingID = PendingPlaybackID.recommendation(recommendation.id)
            pendingPlaybackID = pendingID
            Task {
                await playAlbumRadioRecommendation(recommendation)
                clearPendingPlayback(ifMatching: pendingID)
            }
        }
    }

    func enqueueStationRecommendation(_ recommendation: PlexStationRecommendation) {
        enqueue(fallback: { self.playStationRecommendation(recommendation) }) { server, playQueue, userToken in
            guard let library = self.context.libraryStore?.selectedLibrary else {
                throw PlexAPIError.noReachableServer
            }

            let tracks: [PlexTrack]
            switch recommendation.kind {
            case .artist:
                guard let station = recommendation.station else {
                    throw PlexAPIError.invalidResponse
                }
                tracks = try await self.context.plexService!.createStationPlayQueue(
                    server: server,
                    station: station,
                    userToken: userToken
                ).tracks
            case .album:
                tracks = try await self.context.plexService!.fetchAlbumRadioTracks(
                    server: server,
                    albumRatingKey: recommendation.seedID,
                    userToken: userToken
                )
            }

            return try await self.context.plexService!.addTracksToPlayQueue(
                server: server,
                library: library,
                tracks: tracks,
                playQueueID: playQueue.id,
                playNext: false,
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

    func refreshPlayQueue() {
        guard let playQueue = activeServerPlayQueue else { return }
        performQueueOperation {
            guard let server = self.context.libraryStore?.selectedServer,
                  let userToken = self.context.plexService!.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            return try await self.context.plexService!.refreshPlayQueue(
                server: server,
                playQueueID: playQueue.id,
                itemCount: playQueue.itemCount,
                centeredOn: self.currentTrack?.playQueueItemID,
                userToken: userToken
            )
        }
    }

    func removePlayQueueTrack(id: String) {
        guard id != currentTrack?.id,
              let playQueueItemID = playbackQueue.first(where: { $0.id == id })?.playQueueItemID else {
            return
        }

        performQueueOperation {
            guard let playQueue = self.activeServerPlayQueue,
                  let server = self.context.libraryStore?.selectedServer,
                  let userToken = self.context.plexService!.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            return try await self.context.plexService!.removePlayQueueItem(
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
            guard let server = self.context.libraryStore?.selectedServer,
                  let userToken = self.context.plexService!.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            return try await self.context.plexService!.movePlayQueueItem(
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
              let currentIdx = playbackQueue.firstIndex(where: { $0.id == currentTrack.id }),
              let server = self.context.libraryStore?.selectedServer,
              let userToken = self.context.plexService!.authService.authToken,
              let playQueue = activeServerPlayQueue else {
            return
        }

        guard currentIdx < playbackQueue.count - 1 else { return }
        guard !isQueueOperationInProgress else { return }

        let previousOrderedPlaybackQueue = orderedPlaybackQueue
        let previousPlaybackQueue = playbackQueue
        let previousVisiblePlayQueue = visiblePlayQueue
        let previousUsesServerManagedQueueOrder = usesServerManagedQueueOrder
        let previousCurrentQueueIndex = currentQueueIndex
        let previousActiveServerPlayQueue = activeServerPlayQueue
        let previousIsShuffleEnabled = isShuffleEnabled
        let retainedTracks = Array(playbackQueue.prefix(currentIdx + 1))
        let retainedVisibleTracks: [PlexTrack]
        if let visibleCurrentIndex = visiblePlayQueue.firstIndex(where: { $0.id == currentTrack.id }) {
            retainedVisibleTracks = Array(visiblePlayQueue.prefix(visibleCurrentIndex + 1))
        } else {
            retainedVisibleTracks = [currentTrack]
        }

        orderedPlaybackQueue = retainedTracks
        playbackQueue = retainedTracks
        visiblePlayQueue = retainedVisibleTracks
        self.context.libraryStore?.refreshQueueStationRecommendations(for: visiblePlayQueue)
        usesServerManagedQueueOrder = false
        currentQueueIndex = retainedTracks.count - 1
        activeServerPlayQueue = nil
        isShuffleEnabled = false
        isQueueOperationInProgress = true
        Task {
            do {
                try await self.context.plexService!.clearPlayQueue(
                    server: server,
                    playQueueID: playQueue.id,
                    userToken: userToken
                )
                logDebug("Cleared server play queue")
            } catch {
                orderedPlaybackQueue = previousOrderedPlaybackQueue
                playbackQueue = previousPlaybackQueue
                visiblePlayQueue = previousVisiblePlayQueue
                self.context.libraryStore?.refreshQueueStationRecommendations(for: visiblePlayQueue)
                usesServerManagedQueueOrder = previousUsesServerManagedQueueOrder
                currentQueueIndex = previousCurrentQueueIndex
                activeServerPlayQueue = previousActiveServerPlayQueue
                isShuffleEnabled = previousIsShuffleEnabled
                logDebug("Clear upcoming failed: \(error.localizedDescription)")
            }
            isQueueOperationInProgress = false
        }
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()

        if let activeServerPlayQueue,
           let server = self.context.libraryStore?.selectedServer,
           let userToken = self.context.plexService!.authService.authToken {
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
           let server = self.context.libraryStore?.selectedServer,
           let userToken = self.context.plexService!.authService.authToken,
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

    func handleTrackEnded() {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return }

        if currentQueueIndex < playbackQueue.count - 1 {
            currentQueueIndex += 1
            Task {
                await playCurrentTrack()
                await refreshServerQueueAfterPlaybackAdvance()
                logDebug("Auto-advanced to \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
            }
            return
        }

        self.context.playbackEngine?.stopPlayback()
    }

    func advanceToNextTrack() {
        guard !playbackQueue.isEmpty else { return }
        let nextIndex = min(currentQueueIndex + 1, playbackQueue.count - 1)
        guard nextIndex != currentQueueIndex else { return }

        currentQueueIndex = nextIndex
        Task {
            await playCurrentTrack()
            await refreshServerQueueAfterPlaybackAdvance()
        }
    }

    func goToPreviousTrack() {
        guard !playbackQueue.isEmpty else { return }
        let previousIndex = max(currentQueueIndex - 1, 0)
        guard previousIndex != currentQueueIndex else { return }

        currentQueueIndex = previousIndex
        Task {
            await playCurrentTrack()
            await refreshServerQueueAfterPlaybackAdvance()
        }
    }

    func resetQueue() {
        orderedPlaybackQueue = []
        playbackQueue = []
        visiblePlayQueue = []
        self.context.libraryStore?.resetQueueStationRecommendations()
        pendingPlaybackID = nil
        pendingPlaybackSource = nil
        relatedAlbumsTask?.cancel()
        usesServerManagedQueueOrder = false
        activePlaybackSource = nil
        activeServerPlayQueue = nil
        currentQueueIndex = 0
        isShuffleEnabled = false
        isQueueOperationInProgress = false
    }

    // MARK: - Private

    private var lastRelatedAlbumsRatingKey: String?
    private var relatedAlbumsTask: Task<Void, Never>?

    private func clearPendingPlayback(ifMatching id: String) {
        guard pendingPlaybackID == id else { return }
        pendingPlaybackID = nil
        pendingPlaybackSource = nil
    }

    private func playAlbumRadioRecommendation(_ recommendation: PlexStationRecommendation) async {
        await playServerQueueSelection(named: recommendation.title) {
            guard let server = self.context.libraryStore?.selectedServer,
                  let library = self.context.libraryStore?.selectedLibrary,
                  let userToken = self.context.plexService!.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            let tracks = try await self.context.plexService!.fetchAlbumRadioTracks(
                server: server,
                albumRatingKey: recommendation.seedID,
                userToken: userToken
            )
            return try await self.context.plexService!.createTrackListPlayQueue(
                server: server,
                library: library,
                tracks: tracks,
                userToken: userToken
            )
        }
    }

    private func playAlbumSelection(_ album: PlexAlbum) async {
        guard let library = self.context.libraryStore?.selectedLibrary else { return }
        activePlaybackSource = .album(album, library)

        await playSelection(named: album.title) {
            guard let server = self.context.libraryStore?.selectedServer,
                  let userToken = self.context.plexService!.authService.authToken else {
                throw PlexAPIError.noReachableServer
            }

            let tracks = try await self.context.plexService!.fetchAlbumTracks(server: server, album: album, userToken: userToken)
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
            let snapshot = try await self.context.plexService!.createAlbumPlayQueue(
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
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
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

    private func playSelection(named name: String, loader: @escaping () async throws -> [PlexTrack]) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting playback for \(name)")

        do {
            let tracks = try await loader()
            activeServerPlayQueue = nil
            replacePlaybackQueue(with: tracks, keepingTrackID: tracks.first?.id)
            logDebug("Loaded \(tracks.count) track(s) for playback")
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch is AlbumServerQueuePlaybackHandled {
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Playback load failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
    }

    private func playServerQueueSelection(named name: String, loader: @escaping () async throws -> PlexPlayQueueSnapshot) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting playback for \(name)")

        do {
            let snapshot = try await loader()
            adoptServerPlayQueue(snapshot, keepingTrackID: snapshot.selectedTrackID ?? snapshot.tracks.first?.id)
            logDebug("Loaded \(snapshot.tracks.count) track(s) from Plex play queue")
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Playback load failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
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
            self.context.playbackEngine?.updateNowPlaying(from: currentTrack)
        }
    }

    private func replacePlaybackQueue(with tracks: [PlexTrack], keepingTrackID: String?, usesServerOrder: Bool = false) {
        orderedPlaybackQueue = tracks
        usesServerManagedQueueOrder = usesServerOrder
        visiblePlayQueue = usesServerOrder ? tracks : []
        self.context.libraryStore?.refreshQueueStationRecommendations(for: visiblePlayQueue)
        applyPlaybackOrder(keepingTrackID: keepingTrackID)
    }

    private func applyPlaybackOrder(keepingTrackID: String?) {
        guard !orderedPlaybackQueue.isEmpty else {
            playbackQueue = []
            currentQueueIndex = 0
            self.context.playbackEngine?.playbackState = .stopped
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

    private func playCurrentTrack() async {
        guard let track = self.currentTrack else { return }
        await self.context.playbackEngine?.play(track: track)
    }

    private func refreshServerQueueAfterPlaybackAdvance() async {
        guard let playQueue = activeServerPlayQueue,
              let server = self.context.libraryStore?.selectedServer,
              let userToken = self.context.plexService!.authService.authToken else {
            return
        }

        let keepingTrackID = currentTrack?.id
        let centerItemID = currentTrack?.playQueueItemID
        try? await Task.sleep(for: .milliseconds(300))

        do {
            let snapshot = try await self.context.plexService!.refreshPlayQueue(
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

    private func enqueue(
        fallback: @escaping () -> Void,
        loader: @escaping (PlexServer, ServerPlayQueueContext, String) async throws -> PlexPlayQueueSnapshot
    ) {
        guard let playQueue = activeServerPlayQueue else {
            fallback()
            return
        }

        performQueueOperation {
            guard let server = self.context.libraryStore?.selectedServer,
                  let userToken = self.context.plexService!.authService.authToken else {
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
                logDebug("Queue update failed: \(error.localizedDescription)")
            }
            self.isQueueOperationInProgress = false
        }
    }

    private func updateServerManagedShuffle(enabled: Bool, server: PlexServer, userToken: String, playQueue: ServerPlayQueueContext, keepingTrackID: String?) async {
        do {
            let snapshot = try await {
                if enabled {
                    return try await self.context.plexService!.shufflePlayQueue(
                        server: server,
                        playQueueID: playQueue.id,
                        itemCount: playQueue.itemCount,
                        userToken: userToken
                    )
                }
                return try await self.context.plexService!.unshufflePlayQueue(
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
            let snapshot = try await self.context.plexService!.createAlbumPlayQueue(
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
            logDebug("Shuffle update failed: \(error.localizedDescription)")
        }
    }

    private func logDebug(_ message: String) {
        PlexLog.debug(message, category: .queue)
    }
}
