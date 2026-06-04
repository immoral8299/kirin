import Foundation

@MainActor
final class QueueManager: ObservableObject {
    @Published var visiblePlayQueue: [MediaTrack] = []
    @Published var isQueueOperationInProgress = false
    @Published var isShuffleEnabled = false
    @Published private var isShuffleOperationInProgress = false
    @Published private(set) var pendingPlaybackID: String?
    @Published private(set) var pendingPlaybackSource: String?

    private let context: StoreContext
    private var orderedPlaybackQueue: [MediaTrack] = []
    private var playbackQueue: [MediaTrack] = []
    @Published private var currentQueueIndex: Int = 0
    private var playQueueID: Int?
    private var playQueueVersion: Int?
    private var playQueueTotalCount: Int = 0

    init(context: StoreContext) {
        self.context = context
    }

    var currentTrack: MediaTrack? {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return nil }
        return playbackQueue[currentQueueIndex]
    }

    var nextTrack: MediaTrack? {
        let nextIndex = currentQueueIndex + 1
        guard playbackQueue.indices.contains(nextIndex) else { return nil }
        return playbackQueue[nextIndex]
    }

    var hasEditablePlayQueue: Bool { !playbackQueue.isEmpty }

    var canGoToPreviousTrack: Bool {
        currentQueueIndex > 0 && playbackQueue.indices.contains(currentQueueIndex)
    }

    var canGoToNextTrack: Bool {
        playbackQueue.indices.contains(currentQueueIndex) && currentQueueIndex < playbackQueue.count - 1
    }

    var canShuffle: Bool {
        max(playQueueTotalCount, orderedPlaybackQueue.count, playbackQueue.count) > 1 &&
            !isQueueOperationInProgress &&
            !isShuffleOperationInProgress
    }

    var currentPlayQueueTrackID: String? {
        currentTrack?.id
    }

    var currentServerPlayQueueID: Int? {
        context.mediaService.supportsServerManagedQueue ? playQueueID : nil
    }

    var allTracks: [MediaTrack] { playbackQueue }

    // MARK: - Play

    func playAlbum(_ album: MediaAlbum) {
        let pendingID = PendingPlaybackID.album(album.id)
        pendingPlaybackID = pendingID
        Task {
            await playAlbumSelection(album)
            clearPendingPlayback(ifMatching: pendingID)
        }
    }

    func playPlaylist(_ playlist: MediaPlaylist) {
        let pendingID = PendingPlaybackID.playlist(playlist.id)
        pendingPlaybackID = pendingID
        Task {
            await playPlaylistSelection(playlist)
            clearPendingPlayback(ifMatching: pendingID)
        }
    }

    func playStation(_ station: MediaStation) {
        let pendingID = PendingPlaybackID.station(station.id)
        pendingPlaybackID = pendingID
        Task {
            await playStationSelection(station)
            clearPendingPlayback(ifMatching: pendingID)
        }
    }

    func playTracks(_ tracks: [MediaTrack], startingAt trackID: String?) {
        guard !tracks.isEmpty else { return }
        let pendingID = PendingPlaybackID.track(trackID ?? tracks.first?.id ?? "")
        pendingPlaybackID = pendingID
        Task {
            await playTrackSelection(tracks, startingAt: trackID)
            clearPendingPlayback(ifMatching: pendingID)
        }
    }

    func enqueueStationRecommendation(_ recommendation: MediaStationRecommendation, playNext: Bool) {
        guard let plexService = context.plexService,
              let server = context.libraryStore?.selectedPlexServer,
              let userToken = plexService.authService.authToken,
              let currentTrack else {
            playStationRecommendation(recommendation)
            return
        }

        switch recommendation.kind {
        case .artist:
            guard let station = recommendation.station else { return }
            Task {
                do {
                    if context.mediaService.supportsServerManagedQueue, let playQueueID {
                        let snapshot = try await context.mediaService.addStationToQueue(
                            stationKey: station.key,
                            playQueueID: playQueueID,
                            playNext: playNext
                        )
                        applyServerSnapshot(snapshot, keepingTrackID: currentTrack.id)
                        logDebug("Added station recommendation to server play queue \(snapshot.id)")
                    } else {
                        let snapshot = try await context.mediaService.createStationPlayQueue(stationKey: station.key)
                        let tracks = snapshot.tracks
                        if playNext {
                            let insertIndex = currentQueueIndex + 1
                            orderedPlaybackQueue.insert(contentsOf: tracks, at: insertIndex)
                        } else {
                            orderedPlaybackQueue.append(contentsOf: tracks)
                        }
                        applyPlaybackOrder(keepingTrackID: currentTrack.id)
                        logDebug("Enqueued \(tracks.count) track(s) from station recommendation")
                    }
                } catch {
                    logDebug("Enqueue station recommendation failed: \(error.localizedDescription)")
                }
            }
        case .album:
            Task {
                do {
                    let library = context.libraryStore?.selectedPlexLibrary ?? PlexMusicLibrary(id: "", title: "", uuid: nil)
                    let tracks = try await plexService.fetchAlbumRadioTracks(
                        server: server, albumRatingKey: recommendation.seedID, userToken: userToken
                    )
                    if context.mediaService.supportsServerManagedQueue, let playQueueID {
                        let snapshot = try await plexService.addTracksToPlayQueue(
                            server: server,
                            library: library,
                            tracks: tracks,
                            playQueueID: playQueueID,
                            playNext: playNext,
                            userToken: userToken
                        )
                        applyServerSnapshot(snapshot.mediaPlayQueueSnapshot, keepingTrackID: currentTrack.id)
                        logDebug("Added album radio to server play queue \(snapshot.id)")
                    } else {
                        let snapshot = try await plexService.createTrackListPlayQueue(
                            server: server, library: library, tracks: tracks, userToken: userToken
                        )
                        let mediaTracks = snapshot.tracks.map(\.mediaTrack)
                        if playNext {
                            let insertIndex = currentQueueIndex + 1
                            orderedPlaybackQueue.insert(contentsOf: mediaTracks, at: insertIndex)
                        } else {
                            orderedPlaybackQueue.append(contentsOf: mediaTracks)
                        }
                        applyPlaybackOrder(keepingTrackID: currentTrack.id)
                        logDebug("Enqueued \(mediaTracks.count) track(s) from album radio")
                    }
                } catch {
                    logDebug("Enqueue album radio failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Enqueue

    func enqueueAlbum(_ album: MediaAlbum, playNext: Bool) {
        guard let currentTrack else {
            playAlbum(album)
            return
        }
        Task {
            do {
                if context.mediaService.supportsServerManagedQueue, let playQueueID {
                    let snapshot = try await context.mediaService.addAlbumToQueue(
                        albumID: album.id,
                        playQueueID: playQueueID,
                        playNext: playNext
                    )
                    applyServerSnapshot(snapshot, keepingTrackID: currentTrack.id)
                    logDebug("Added \(album.title) to server play queue \(snapshot.id)")
                    return
                }

                let tracks = try await context.mediaService.fetchAlbumTracks(albumID: album.id)
                if playNext {
                    let insertIndex = currentQueueIndex + 1
                    orderedPlaybackQueue.insert(contentsOf: tracks, at: insertIndex)
                } else {
                    orderedPlaybackQueue.append(contentsOf: tracks)
                }
                applyPlaybackOrder(keepingTrackID: currentTrack.id)
                logDebug("Enqueued \(tracks.count) track(s) from \(album.title)")
            } catch {
                logDebug("Enqueue album failed: \(error.localizedDescription)")
            }
        }
    }

    func enqueuePlaylist(_ playlist: MediaPlaylist, playNext: Bool) {
        guard let currentTrack else {
            playPlaylist(playlist)
            return
        }
        Task {
            do {
                if context.mediaService.supportsServerManagedQueue, let playQueueID {
                    let snapshot = try await context.mediaService.addPlaylistToQueue(
                        playlistID: playlist.id,
                        playQueueID: playQueueID,
                        playNext: playNext
                    )
                    applyServerSnapshot(snapshot, keepingTrackID: currentTrack.id)
                    logDebug("Added \(playlist.title) to server play queue \(snapshot.id)")
                    return
                }

                let tracks = try await context.mediaService.fetchPlaylistTracks(playlistID: playlist.id)
                if playNext {
                    let insertIndex = currentQueueIndex + 1
                    orderedPlaybackQueue.insert(contentsOf: tracks, at: insertIndex)
                } else {
                    orderedPlaybackQueue.append(contentsOf: tracks)
                }
                applyPlaybackOrder(keepingTrackID: currentTrack.id)
                logDebug("Enqueued \(tracks.count) track(s) from \(playlist.title)")
            } catch {
                logDebug("Enqueue playlist failed: \(error.localizedDescription)")
            }
        }
    }

    func enqueueStation(_ station: MediaStation, playNext: Bool) {
        guard let currentTrack else {
            playStation(station)
            return
        }

        Task {
            do {
                if context.mediaService.supportsServerManagedQueue, let playQueueID {
                    let snapshot = try await context.mediaService.addStationToQueue(
                        stationKey: station.key,
                        playQueueID: playQueueID,
                        playNext: playNext
                    )
                    applyServerSnapshot(snapshot, keepingTrackID: currentTrack.id)
                    logDebug("Added station \(station.title) to server play queue \(snapshot.id)")
                    return
                }

                let snapshot = try await context.mediaService.createStationPlayQueue(stationKey: station.key)
                let tracks = snapshot.tracks
                if playNext {
                    let insertIndex = currentQueueIndex + 1
                    orderedPlaybackQueue.insert(contentsOf: tracks, at: insertIndex)
                } else {
                    orderedPlaybackQueue.append(contentsOf: tracks)
                }
                applyPlaybackOrder(keepingTrackID: currentTrack.id)
                logDebug("Enqueued \(tracks.count) track(s) from station \(station.title)")
            } catch {
                logDebug("Enqueue station failed: \(error.localizedDescription)")
            }
        }
    }

    func enqueueTracks(_ tracks: [MediaTrack], playNext: Bool) {
        guard !tracks.isEmpty else { return }
        guard let currentTrack else {
            playTracks(tracks, startingAt: tracks.first?.id)
            return
        }

        Task {
            do {
                if context.mediaService.supportsServerManagedQueue, let playQueueID {
                    let snapshot = try await context.mediaService.addTracksToQueue(
                        tracks: tracks,
                        playQueueID: playQueueID,
                        playNext: playNext
                    )
                    applyServerSnapshot(snapshot, keepingTrackID: currentTrack.id)
                    logDebug("Added \(tracks.count) track(s) to server play queue \(snapshot.id)")
                    return
                }

                if playNext {
                    let insertIndex = currentQueueIndex + 1
                    orderedPlaybackQueue.insert(contentsOf: tracks, at: insertIndex)
                } else {
                    orderedPlaybackQueue.append(contentsOf: tracks)
                }
                applyPlaybackOrder(keepingTrackID: currentTrack.id)
                logDebug("Enqueued \(tracks.count) track(s)")
            } catch {
                self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
                logDebug("Enqueue tracks failed: \(error.localizedDescription)")
            }
        }
    }

    func playStationRecommendation(_ recommendation: MediaStationRecommendation) {
        guard let plexService = context.plexService,
              let server = context.libraryStore?.selectedPlexServer,
              let userToken = plexService.authService.authToken else { return }

        switch recommendation.kind {
        case .artist:
            guard let station = recommendation.station else { return }
            let pendingID = PendingPlaybackID.recommendation(recommendation.id)
            pendingPlaybackID = pendingID
            Task {
                await playStationSelection(station)
                clearPendingPlayback(ifMatching: pendingID)
            }
        case .album:
            let pendingID = PendingPlaybackID.recommendation(recommendation.id)
            pendingPlaybackID = pendingID
            Task {
                let library = PlexMusicLibrary(id: "", title: "", uuid: nil)
                await playAlbumRadioRecommendation(recommendation, plexService: plexService, server: server, library: library, userToken: userToken)
                clearPendingPlayback(ifMatching: pendingID)
            }
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
        }
    }

    func removePlayQueueTrack(id: String) {
        guard let removeIndex = playbackQueue.firstIndex(where: { $0.id == id }) else { return }
        if context.mediaService.supportsServerManagedQueue,
           let playQueueID {
            let playQueueItemID = playbackQueue[removeIndex].playQueueItemID ?? playbackQueue[removeIndex].id
            Task {
                await performQueueOperation {
                    let snapshot = try await self.context.mediaService.removeQueueItem(
                        playQueueID: playQueueID,
                        playQueueItemID: playQueueItemID,
                        itemCount: max(self.playQueueTotalCount, self.playbackQueue.count)
                    )
                    self.applyServerSnapshot(snapshot, keepingTrackID: self.currentTrack?.id)
                }
            }
            return
        }

        let wasCurrent = id == currentTrack?.id
        if removeIndex < currentQueueIndex {
            currentQueueIndex -= 1
        }

        orderedPlaybackQueue.removeAll { $0.id == id }
        playbackQueue.remove(at: removeIndex)
        visiblePlayQueue.removeAll { $0.id == id }

        if playbackQueue.isEmpty {
            currentQueueIndex = 0
            context.playbackEngine?.resetForNewTrack()
        } else if wasCurrent {
            currentQueueIndex = min(currentQueueIndex, playbackQueue.count - 1)
            Task {
                await playCurrentTrack()
            }
        } else {
            updatePrebufferedNextTrack()
        }
    }

    func movePlayQueueTrack(id: String, before targetID: String) {
        guard id != targetID,
              id != currentTrack?.id,
              let sourceIndex = playbackQueue.firstIndex(where: { $0.id == id }),
              let targetIndex = playbackQueue.firstIndex(where: { $0.id == targetID }),
              sourceIndex > currentQueueIndex, targetIndex > currentQueueIndex else {
            return
        }

        if context.mediaService.supportsServerManagedQueue,
           let playQueueID {
            let playQueueItemID = playbackQueue[sourceIndex].playQueueItemID ?? playbackQueue[sourceIndex].id
            let afterPlayQueueItemID: String?
            if targetIndex > 0 {
                afterPlayQueueItemID = playbackQueue[targetIndex - 1].playQueueItemID ?? playbackQueue[targetIndex - 1].id
            } else {
                afterPlayQueueItemID = nil
            }

            Task {
                await performQueueOperation {
                    let snapshot = try await self.context.mediaService.moveQueueItem(
                        playQueueID: playQueueID,
                        playQueueItemID: playQueueItemID,
                        afterPlayQueueItemID: afterPlayQueueItemID,
                        itemCount: max(self.playQueueTotalCount, self.playbackQueue.count)
                    )
                    self.applyServerSnapshot(snapshot, keepingTrackID: self.currentTrack?.id)
                }
            }
            return
        }

        let track = playbackQueue[sourceIndex]
        playbackQueue.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        playbackQueue.insert(track, at: adjustedTarget)
        visiblePlayQueue = playbackQueue
        updatePrebufferedNextTrack()
    }

    func clearUpcomingPlayQueueTracks() {
        guard let currentTrack,
              let currentIdx = playbackQueue.firstIndex(where: { $0.id == currentTrack.id }),
              currentIdx < playbackQueue.count - 1 else {
            return
        }

        if context.mediaService.supportsServerManagedQueue, let playQueueID {
            let upcomingTracks = Array(playbackQueue.dropFirst(currentIdx + 1))
            Task {
                await performQueueOperation {
                    var latestSnapshot: PlayQueueSnapshot?
                    for track in upcomingTracks.reversed() {
                        let playQueueItemID = track.playQueueItemID ?? track.id
                        latestSnapshot = try await self.context.mediaService.removeQueueItem(
                            playQueueID: playQueueID,
                            playQueueItemID: playQueueItemID,
                            itemCount: max(self.playQueueTotalCount, self.playbackQueue.count)
                        )
                    }

                    if let latestSnapshot {
                        self.applyServerSnapshot(latestSnapshot, keepingTrackID: currentTrack.id)
                    } else {
                        self.orderedPlaybackQueue = Array(self.orderedPlaybackQueue.prefix(currentIdx + 1))
                        self.playbackQueue = Array(self.playbackQueue.prefix(currentIdx + 1))
                        self.visiblePlayQueue = self.playbackQueue
                        self.playQueueTotalCount = self.playbackQueue.count
                    }
                }
            }
            return
        }

        orderedPlaybackQueue = Array(orderedPlaybackQueue.prefix(currentIdx + 1))
        playbackQueue = Array(playbackQueue.prefix(currentIdx + 1))
        visiblePlayQueue = playbackQueue
        isShuffleEnabled = false
        updatePrebufferedNextTrack()
        logDebug("Cleared upcoming tracks")
    }

    func toggleShuffle() {
        guard canShuffle else { return }
        let nextShuffleState = !isShuffleEnabled
        let trackIDAtToggle = currentTrack?.id
        let previousShuffleState = isShuffleEnabled
        let previousOrderedQueue = orderedPlaybackQueue

        isShuffleEnabled = nextShuffleState
        applyPlaybackOrder(keepingTrackID: trackIDAtToggle)
        logDebug(isShuffleEnabled ? "Shuffle enabled" : "Shuffle disabled")

        if context.mediaService.supportsServerManagedQueue, let playQueueID {
            isShuffleOperationInProgress = true
            isQueueOperationInProgress = true

            Task {
                defer {
                    self.isShuffleOperationInProgress = false
                    self.isQueueOperationInProgress = false
                }

                do {
                    let snapshot = try await (nextShuffleState
                        ? self.context.mediaService.shufflePlayQueue(id: playQueueID)
                        : self.context.mediaService.unshufflePlayQueue(id: playQueueID))
                    self.applyServerSnapshot(snapshot, keepingTrackID: self.currentTrack?.id)
                    self.isShuffleEnabled = snapshot.isShuffled
                } catch {
                    let currentTrackID = self.currentTrack?.id ?? trackIDAtToggle
                    self.isShuffleEnabled = previousShuffleState
                    self.orderedPlaybackQueue = previousOrderedQueue
                    self.applyPlaybackOrder(keepingTrackID: currentTrackID)
                    self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
                    self.logDebug("Shuffle failed: \(error.localizedDescription)")
                }
            }
            return
        }
    }

    func handleTrackEnded() {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return }

        if currentQueueIndex < playbackQueue.count - 1 {
            currentQueueIndex += 1
            Task {
                await playCurrentTrack()
                logDebug("Auto-advanced to \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
            }
            return
        }

        self.context.playbackEngine?.stopPlayback()
    }

    func advanceToNextTrack() {
        guard canGoToNextTrack else { return }
        let nextIndex = min(currentQueueIndex + 1, playbackQueue.count - 1)
        guard nextIndex != currentQueueIndex else { return }

        currentQueueIndex = nextIndex
        Task {
            await playCurrentTrack()
        }
    }

    func goToPreviousTrack() {
        guard canGoToPreviousTrack else { return }
        let previousIndex = max(currentQueueIndex - 1, 0)
        guard previousIndex != currentQueueIndex else { return }

        currentQueueIndex = previousIndex
        Task {
            await playCurrentTrack()
        }
    }

    func resetQueue() {
        orderedPlaybackQueue = []
        playbackQueue = []
        visiblePlayQueue = []
        pendingPlaybackID = nil
        pendingPlaybackSource = nil
        currentQueueIndex = 0
        isShuffleEnabled = false
        isShuffleOperationInProgress = false
        isQueueOperationInProgress = false
        playQueueID = nil
        playQueueVersion = nil
        playQueueTotalCount = 0
        context.playbackEngine?.prebufferNextTrack(nil)
    }

    // MARK: - Private

    private func clearPendingPlayback(ifMatching id: String) {
        guard pendingPlaybackID == id else { return }
        pendingPlaybackID = nil
        pendingPlaybackSource = nil
    }

    private func playAlbumSelection(_ album: MediaAlbum) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting playback for \(album.title)")

        do {
            if context.mediaService.supportsServerManagedQueue {
                let tracks = try await context.mediaService.fetchAlbumTracks(albumID: album.id)
                guard let firstTrackID = tracks.first?.ratingKey ?? tracks.first?.id else {
                    replacePlaybackQueue(with: [MediaTrack](), keepingTrackID: nil)
                    return
                }
                let snapshot = try await context.mediaService.createAlbumPlayQueue(
                    albumID: album.id,
                    startingTrackRatingKey: firstTrackID,
                    shuffle: isShuffleEnabled
                )
                replacePlaybackQueue(with: snapshot)
                logDebug("Loaded server play queue \(snapshot.id) with \(snapshot.tracks.count) track(s)")
            } else {
                let tracks = try await context.mediaService.fetchAlbumTracks(albumID: album.id)
                replacePlaybackQueue(with: tracks, keepingTrackID: tracks.first?.id)
                logDebug("Loaded \(tracks.count) track(s) for playback")
            }
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Playback load failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
    }

    private func playPlaylistSelection(_ playlist: MediaPlaylist) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting playback for \(playlist.title)")

        do {
            if context.mediaService.supportsServerManagedQueue {
                let snapshot = try await context.mediaService.createPlaylistPlayQueue(
                    playlistID: playlist.id,
                    shuffle: isShuffleEnabled
                )
                replacePlaybackQueue(with: snapshot)
                logDebug("Loaded server play queue \(snapshot.id) with \(snapshot.tracks.count) track(s)")
            } else {
                let tracks = try await context.mediaService.fetchPlaylistTracks(playlistID: playlist.id)
                replacePlaybackQueue(with: tracks, keepingTrackID: tracks.first?.id)
                logDebug("Loaded \(tracks.count) track(s) for playback")
            }
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Playback load failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
    }

    private func playStationSelection(_ station: MediaStation) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting playback for station \(station.title)")

        do {
            let snapshot = try await context.mediaService.createStationPlayQueue(stationKey: station.key)
            replacePlaybackQueue(with: snapshot)
            logDebug("Loaded \(snapshot.tracks.count) track(s) from station")
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Station playback failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
    }

    private func playTrackSelection(_ tracks: [MediaTrack], startingAt trackID: String?) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting playback from search results")

        do {
            let selectedTrackID = trackID ?? tracks.first?.id
            if context.mediaService.supportsServerManagedQueue {
                let snapshot = try await context.mediaService.createTrackListPlayQueue(tracks: tracks)
                replacePlaybackQueue(with: snapshot)
                applyPlaybackOrder(keepingTrackID: selectedTrackID ?? snapshot.selectedTrackID ?? snapshot.tracks.first?.id)
                logDebug("Loaded server play queue \(snapshot.id) with \(snapshot.tracks.count) track(s)")
            } else {
                replacePlaybackQueue(with: tracks, keepingTrackID: selectedTrackID)
                logDebug("Loaded \(tracks.count) track(s) for playback")
            }
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Track-list playback failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
    }

    private func playAlbumRadioRecommendation(_ recommendation: MediaStationRecommendation, plexService: PlexService, server: PlexServer, library: PlexMusicLibrary, userToken: String) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting album radio for \(recommendation.title)")

        do {
            let tracks = try await plexService.fetchAlbumRadioTracks(
                server: server, albumRatingKey: recommendation.seedID, userToken: userToken
            )
            let snapshot = try await plexService.createTrackListPlayQueue(
                server: server, library: library, tracks: tracks, userToken: userToken
            )
            replacePlaybackQueue(with: snapshot.mediaPlayQueueSnapshot)
            logDebug("Loaded \(snapshot.tracks.count) track(s) from album radio")
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Album radio failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
    }

    private func replacePlaybackQueue(with tracks: [MediaTrack], keepingTrackID: String?) {
        playQueueID = nil
        playQueueVersion = nil
        playQueueTotalCount = tracks.count
        orderedPlaybackQueue = tracks
        applyPlaybackOrder(keepingTrackID: keepingTrackID)
    }

    private func replacePlaybackQueue(with snapshot: PlayQueueSnapshot) {
        applyServerSnapshot(snapshot, keepingTrackID: snapshot.selectedTrackID ?? snapshot.tracks.first?.id)
    }

    private func applyServerSnapshot(_ snapshot: PlayQueueSnapshot, keepingTrackID: String?) {
        playQueueID = snapshot.id
        playQueueVersion = snapshot.version
        playQueueTotalCount = snapshot.totalCount
        isShuffleEnabled = snapshot.isShuffled
        orderedPlaybackQueue = snapshot.tracks
        applyPlaybackOrder(keepingTrackID: keepingTrackID)
    }

    private func applyPlaybackOrder(keepingTrackID: String?) {
        guard !orderedPlaybackQueue.isEmpty else {
            playbackQueue = []
            visiblePlayQueue = []
            currentQueueIndex = 0
            self.context.libraryStore?.resetQueueStationRecommendations()
            self.context.playbackEngine?.playbackState = .stopped
            self.context.playbackEngine?.prebufferNextTrack(nil)
            return
        }

        if isShuffleEnabled {
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

        visiblePlayQueue = playbackQueue
        self.context.libraryStore?.refreshQueueStationRecommendations(for: playbackQueue)
        updatePrebufferedNextTrack()
    }

    private func performQueueOperation(_ operation: @escaping () async throws -> Void) async {
        guard !isQueueOperationInProgress else { return }
        isQueueOperationInProgress = true
        defer { isQueueOperationInProgress = false }

        do {
            try await operation()
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Play queue operation failed: \(error.localizedDescription)")
        }
    }

    private func shuffledQueue(from tracks: [MediaTrack], keepingTrackID: String?) -> [MediaTrack] {
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
        updatePrebufferedNextTrack()
    }

    private func updatePrebufferedNextTrack() {
        context.playbackEngine?.prebufferNextTrack(nextTrack)
    }

    private func logDebug(_ message: String) {
        PlexLog.debug(message, category: .queue)
    }
}
