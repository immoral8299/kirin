import Foundation

private enum QueueContinuationMode {
    case finite
    case plexArtistStation
    case plexAlbumStation

    var isStationBacked: Bool {
        switch self {
        case .finite:
            return false
        case .plexArtistStation, .plexAlbumStation:
            return true
        }
    }
}

@MainActor
final class QueueManager: ObservableObject {
    private let stationContinuationLookaheadCount = 12
    private let serverQueueReorderDebounceNanoseconds: UInt64 = 350_000_000

    @Published var visiblePlayQueue: [MediaTrack] = []
    @Published var isQueueOperationInProgress = false
    @Published var isShuffleEnabled = false
    @Published private var isShuffleOperationInProgress = false
    @Published private(set) var isQueueReorderSyncInProgress = false
    @Published private(set) var isStationContinuationEnabled = false
    @Published private(set) var pendingPlaybackID: String?
    @Published private(set) var pendingPlaybackSource: String?

    private let context: StoreContext
    private var orderedPlaybackQueue: [MediaTrack] = []
    private var playbackQueue: [MediaTrack] = []
    @Published private var currentQueueIndex: Int = 0
    private var playQueueID: Int?
    private var playQueueVersion: Int?
    private var playQueueTotalCount: Int = 0
    private var continuationMode: QueueContinuationMode = .finite
    private var stationQueuePrefetchTask: Task<Void, Never>?
    private var serverQueueReorderTask: Task<Void, Never>?
    private var queuedQueueOperationTask: Task<Void, Never>?
    private var queuedServerQueueReorderRevision = 0
    private var syncedServerQueueReorderRevision = 0
    private var isFlushingServerQueueReorder = false
    var queueDidChange: (() -> Void)?

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
        guard playbackQueue.indices.contains(currentQueueIndex) else { return false }
        return currentQueueIndex < playbackQueue.count - 1 || canContinueStationQueueFromTail
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

    var isStationContinuationAvailable: Bool {
        continuationMode.isStationBacked &&
            context.mediaService.supportsServerManagedQueue &&
            playQueueID != nil
    }

    var allTracks: [MediaTrack] { playbackQueue }
    var currentQueueIsShuffleEnabled: Bool { isShuffleEnabled }

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
                        applyServerSnapshot(snapshot, keepingTrackID: currentTrack.id, continuationMode: .plexArtistStation)
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
                    guard let station = try await plexService.fetchAlbumStation(
                        server: server, albumRatingKey: recommendation.seedID, userToken: userToken
                    ) else {
                        return
                    }
                    if context.mediaService.supportsServerManagedQueue, let playQueueID {
                        let snapshot = try await plexService.addStationToPlayQueue(
                            server: server,
                            station: station,
                            playQueueID: playQueueID,
                            playNext: playNext,
                            userToken: userToken
                        )
                        applyServerSnapshot(snapshot.mediaPlayQueueSnapshot, keepingTrackID: currentTrack.id, continuationMode: .plexAlbumStation)
                        logDebug("Added album station to server play queue \(snapshot.id)")
                    } else {
                        let snapshot = try await plexService.createStationPlayQueue(
                            server: server, station: station, userToken: userToken
                        )
                        let mediaTracks = snapshot.tracks.map(\.mediaTrack)
                        if playNext {
                            let insertIndex = currentQueueIndex + 1
                            orderedPlaybackQueue.insert(contentsOf: mediaTracks, at: insertIndex)
                        } else {
                            orderedPlaybackQueue.append(contentsOf: mediaTracks)
                        }
                        applyPlaybackOrder(keepingTrackID: currentTrack.id)
                        logDebug("Enqueued \(mediaTracks.count) track(s) from album station")
                    }
                } catch {
                    logDebug("Enqueue album station failed: \(error.localizedDescription)")
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
                    applyServerSnapshot(snapshot, keepingTrackID: currentTrack.id, continuationMode: .plexArtistStation)
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

    func replaceLocalQueue(with tracks: [MediaTrack], startPlayback: Bool) {
        guard !tracks.isEmpty else { return }
        replacePlaybackQueue(with: tracks, keepingTrackID: tracks.first?.id)
        if startPlayback {
            Task {
                await playCurrentTrack()
            }
        }
    }

    func restoreLocalQueue(_ tracks: [MediaTrack], currentTrackID: String?) {
        guard !tracks.isEmpty else { return }
        replacePlaybackQueue(with: tracks, keepingTrackID: currentTrackID ?? tracks.first?.id)
    }

    func restorePersistedQueue(_ tracks: [MediaTrack], currentTrackID: String?, isShuffleEnabled: Bool) {
        guard !tracks.isEmpty else { return }
        resetPendingQueueOperationState()
        continuationMode = .finite
        isStationContinuationEnabled = false
        playQueueID = nil
        playQueueVersion = nil
        playQueueTotalCount = tracks.count
        self.isShuffleEnabled = isShuffleEnabled
        orderedPlaybackQueue = tracks
        playbackQueue = tracks
        if let currentTrackID,
           let index = playbackQueue.firstIndex(where: { $0.id == currentTrackID }) {
            currentQueueIndex = index
        } else {
            currentQueueIndex = 0
        }
        visiblePlayQueue = playbackQueue
        context.libraryStore?.refreshQueueStationRecommendations(for: playbackQueue)
        updatePrebufferedNextTrack()
        queueDidChange?()
    }

    func insertLocalTracksNext(_ tracks: [MediaTrack]) {
        guard !tracks.isEmpty else { return }
        guard let currentTrack else {
            replaceLocalQueue(with: tracks, startPlayback: false)
            return
        }

        var nextQueue = playbackQueue
        let insertIndex = min(currentQueueIndex + 1, nextQueue.count)
        nextQueue.insert(contentsOf: tracks, at: insertIndex)
        applyLocalQueueEdit(nextQueue, keepingTrackID: currentTrack.id)
        logDebug("Inserted \(tracks.count) local track(s) next")
    }

    func appendLocalTracks(_ tracks: [MediaTrack]) {
        guard !tracks.isEmpty else { return }
        guard let currentTrack else {
            replaceLocalQueue(with: tracks, startPlayback: false)
            return
        }

        var nextQueue = playbackQueue
        nextQueue.append(contentsOf: tracks)
        applyLocalQueueEdit(nextQueue, keepingTrackID: currentTrack.id)
        logDebug("Appended \(tracks.count) local track(s)")
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
                await playAlbumRadioRecommendation(recommendation, plexService: plexService, server: server, userToken: userToken)
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

    func playCurrentQueueTrack() {
        guard currentTrack != nil else { return }
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

    func movePlayQueueTrack(id: String, before targetID: String?) {
        guard id != targetID,
              id != currentTrack?.id,
              let sourceIndex = playbackQueue.firstIndex(where: { $0.id == id }),
              sourceIndex > currentQueueIndex else {
            return
        }
        let targetIndex: Int
        if let targetID {
            guard let index = playbackQueue.firstIndex(where: { $0.id == targetID }) else { return }
            targetIndex = index
        } else {
            targetIndex = playbackQueue.count
        }
        guard targetIndex > currentQueueIndex else { return }

        if context.mediaService.supportsServerManagedQueue,
           let playQueueID {
            applyOptimisticQueueMove(sourceIndex: sourceIndex, targetIndex: targetIndex)
            scheduleServerQueueReorderSync(playQueueID: playQueueID)
            return
        }

        applyOptimisticQueueMove(sourceIndex: sourceIndex, targetIndex: targetIndex)
    }

    func clearUpcomingPlayQueueTracks() {
        guard let currentTrack,
              let currentIdx = playbackQueue.firstIndex(where: { $0.id == currentTrack.id }),
              currentIdx < playbackQueue.count - 1 else {
            return
        }

        if context.mediaService.supportsServerManagedQueue, let playQueueID {
            let upcomingTracks = Array(playbackQueue.dropFirst(currentIdx + 1))
            enqueueQueueOperation {
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
            return
        }

        enqueueQueueOperation {
            self.orderedPlaybackQueue = Array(self.orderedPlaybackQueue.prefix(currentIdx + 1))
            self.playbackQueue = Array(self.playbackQueue.prefix(currentIdx + 1))
            self.visiblePlayQueue = self.playbackQueue
            self.isShuffleEnabled = false
            self.context.libraryStore?.refreshQueueStationRecommendations(for: self.playbackQueue)
            self.updatePrebufferedNextTrack()
            self.queueDidChange?()
            self.logDebug("Cleared upcoming tracks")
        }
    }

    func toggleStationContinuation() {
        guard isStationContinuationAvailable else { return }
        enqueueQueueOperation {
            let previousValue = self.isStationContinuationEnabled
            try await withReversibleTransaction("queue.stationContinuation") { transaction in
                transaction.perform {
                    self.setStationContinuationEnabled(!previousValue)
                    self.logDebug(self.isStationContinuationEnabled ? "Station continuation enabled" : "Station continuation disabled")
                } rollback: {
                    self.setStationContinuationEnabled(previousValue)
                }
            }
        }
    }

    func toggleShuffle() {
        guard canShuffle else { return }
        let nextShuffleState = !isShuffleEnabled
        let trackIDAtToggle = currentTrack?.id
        let previousShuffleState = isShuffleEnabled
        let previousOrderedQueue = orderedPlaybackQueue

        if context.mediaService.supportsServerManagedQueue, let playQueueID {
            isShuffleOperationInProgress = true
            isQueueOperationInProgress = true

            Task {
                defer {
                    self.isShuffleOperationInProgress = false
                    self.isQueueOperationInProgress = false
                }

                do {
                    await self.flushPendingServerQueueReorderIfNeeded(playQueueID: playQueueID)
                    try await withReversibleTransaction("queue.shuffle") { transaction in
                        transaction.perform {
                            self.isShuffleEnabled = nextShuffleState
                            self.applyPlaybackOrder(keepingTrackID: trackIDAtToggle)
                            self.logDebug(self.isShuffleEnabled ? "Shuffle enabled" : "Shuffle disabled")
                        } rollback: {
                            let currentTrackID = self.currentTrack?.id ?? trackIDAtToggle
                            self.isShuffleEnabled = previousShuffleState
                            self.orderedPlaybackQueue = previousOrderedQueue
                            self.applyPlaybackOrder(keepingTrackID: currentTrackID)
                        }

                        let snapshot = try await (nextShuffleState
                            ? self.context.mediaService.shufflePlayQueue(id: playQueueID)
                            : self.context.mediaService.unshufflePlayQueue(id: playQueueID))

                        transaction.perform {
                            self.applyServerSnapshot(snapshot, keepingTrackID: self.currentTrack?.id)
                            self.isShuffleEnabled = snapshot.isShuffled
                        }
                    }
                } catch {
                    self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
                    self.logDebug("Shuffle failed: \(error.localizedDescription)")
                }
            }
            return
        }

        isShuffleEnabled = nextShuffleState
        applyPlaybackOrder(keepingTrackID: trackIDAtToggle)
        logDebug(isShuffleEnabled ? "Shuffle enabled" : "Shuffle disabled")
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

        guard canContinueStationQueueFromTail else {
            self.context.playbackEngine?.pauseAtEndOfQueue()
            return
        }

        let exhaustedTrackID = currentTrack?.id
        Task {
            let didAdvance = await continueStationQueueFromTail(after: exhaustedTrackID)
            if didAdvance {
                self.queueDidChange?()
                logDebug("Auto-advanced to \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
            } else {
                self.context.playbackEngine?.pauseAtEndOfQueue()
            }
        }
    }

    func advanceToNextTrack() {
        guard playbackQueue.indices.contains(currentQueueIndex) else { return }

        if currentQueueIndex < playbackQueue.count - 1 {
            currentQueueIndex += 1
            Task {
                await playCurrentTrack()
            }
            return
        }

        guard canContinueStationQueueFromTail else { return }
        let currentTrackID = currentTrack?.id
        Task {
            if await continueStationQueueFromTail(after: currentTrackID) {
                self.queueDidChange?()
            }
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
        continuationMode = .finite
        isStationContinuationEnabled = false
        resetPendingQueueOperationState()
        resetPendingServerQueueReorderState()
        stationQueuePrefetchTask?.cancel()
        stationQueuePrefetchTask = nil
        context.playbackEngine?.prebufferNextTrack(nil)
        queueDidChange?()
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
            let continuationMode: QueueContinuationMode = context.mediaService.supportsServerManagedQueue
                ? .plexArtistStation
                : .finite
            replacePlaybackQueue(with: snapshot, continuationMode: continuationMode)
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

    private func playAlbumRadioRecommendation(_ recommendation: MediaStationRecommendation, plexService: PlexService, server: PlexServer, userToken: String) async {
        self.context.libraryStore?.isLoadingLibrary = true
        self.context.libraryStore?.libraryLoadError = nil
        logDebug("Starting album station for \(recommendation.title)")

        do {
            guard let station = try await plexService.fetchAlbumStation(
                server: server, albumRatingKey: recommendation.seedID, userToken: userToken
            ) else {
                throw PlexAPIError.invalidResponse
            }
            let snapshot = try await plexService.createStationPlayQueue(
                server: server, station: station, userToken: userToken
            )
            replacePlaybackQueue(with: snapshot.mediaPlayQueueSnapshot, continuationMode: .plexAlbumStation)
            logDebug("Loaded \(snapshot.tracks.count) track(s) from album station")
            await playCurrentTrack()
            logDebug("Now playing \(self.context.playbackEngine?.nowPlaying.trackName ?? "")")
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Album station failed: \(error.localizedDescription)")
        }

        self.context.libraryStore?.isLoadingLibrary = false
    }

    private func replacePlaybackQueue(with tracks: [MediaTrack], keepingTrackID: String?) {
        stationQueuePrefetchTask?.cancel()
        stationQueuePrefetchTask = nil
        resetPendingQueueOperationState()
        resetPendingServerQueueReorderState()
        continuationMode = .finite
        isStationContinuationEnabled = false
        playQueueID = nil
        playQueueVersion = nil
        playQueueTotalCount = tracks.count
        orderedPlaybackQueue = tracks
        applyPlaybackOrder(keepingTrackID: keepingTrackID)
    }

    private func replacePlaybackQueue(with snapshot: PlayQueueSnapshot, continuationMode: QueueContinuationMode = .finite) {
        stationQueuePrefetchTask?.cancel()
        stationQueuePrefetchTask = nil
        resetPendingQueueOperationState()
        resetPendingServerQueueReorderState()
        applyServerSnapshot(snapshot, keepingTrackID: snapshot.selectedTrackID ?? snapshot.tracks.first?.id, continuationMode: continuationMode)
    }

    private func applyServerSnapshot(_ snapshot: PlayQueueSnapshot, keepingTrackID: String?, continuationMode: QueueContinuationMode? = nil) {
        playQueueID = snapshot.id
        playQueueVersion = snapshot.version
        playQueueTotalCount = snapshot.totalCount
        isShuffleEnabled = snapshot.isShuffled
        if let continuationMode {
            self.continuationMode = continuationMode
            isStationContinuationEnabled = continuationMode.isStationBacked
        } else if !self.continuationMode.isStationBacked {
            isStationContinuationEnabled = false
        }
        orderedPlaybackQueue = snapshot.tracks
        applyPlaybackOrder(keepingTrackID: keepingTrackID)
    }

    private func applyLocalQueueEdit(_ tracks: [MediaTrack], keepingTrackID: String?) {
        stationQueuePrefetchTask?.cancel()
        stationQueuePrefetchTask = nil
        resetPendingQueueOperationState()
        resetPendingServerQueueReorderState()
        continuationMode = .finite
        isStationContinuationEnabled = false
        playQueueID = nil
        playQueueVersion = nil
        playQueueTotalCount = tracks.count
        orderedPlaybackQueue = tracks
        playbackQueue = tracks
        if let keepingTrackID,
           let index = playbackQueue.firstIndex(where: { $0.id == keepingTrackID }) {
            currentQueueIndex = index
        } else {
            currentQueueIndex = 0
        }
        visiblePlayQueue = playbackQueue
        self.context.libraryStore?.refreshQueueStationRecommendations(for: playbackQueue)
        updatePrebufferedNextTrack()
        queueDidChange?()
    }

    private func applyPlaybackOrder(keepingTrackID: String?) {
        guard !orderedPlaybackQueue.isEmpty else {
            continuationMode = .finite
            isStationContinuationEnabled = false
            playbackQueue = []
            visiblePlayQueue = []
            currentQueueIndex = 0
            self.context.libraryStore?.resetQueueStationRecommendations()
            self.context.playbackEngine?.playbackState = .stopped
            self.context.playbackEngine?.prebufferNextTrack(nil)
            queueDidChange?()
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
        queueDidChange?()
    }

    private var canContinueStationQueueFromTail: Bool {
        isStationContinuationAvailable &&
            isStationContinuationEnabled &&
            playbackQueue.indices.contains(currentQueueIndex) &&
            currentQueueIndex == playbackQueue.count - 1
    }

    private func enqueueQueueOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        let previousTask = queuedQueueOperationTask
        queuedQueueOperationTask = Task { @MainActor [weak self] in
            _ = await previousTask?.result
            guard let self else { return }
            await self.performQueueOperation(operation)
        }
    }

    private func continueStationQueueFromTail(after currentTrackID: String?) async -> Bool {
        guard canContinueStationQueueFromTail,
              let playQueueID,
              let currentTrackID else {
            return false
        }

        let centeredOnItemID = currentTrack?.playQueueItemID ?? currentTrack?.id

        do {
            let snapshot = try await context.mediaService.refreshPlayQueue(
                id: playQueueID,
                itemCount: max(playQueueTotalCount, playbackQueue.count) + stationContinuationLookaheadCount,
                centeredOn: centeredOnItemID
            )
            guard currentTrack?.id == currentTrackID else {
                return false
            }
            guard snapshot.tracks.contains(where: { $0.id == currentTrackID }) else {
                logDebug("Station queue refresh did not include current track \(currentTrackID)")
                return false
            }

            applyServerSnapshot(snapshot, keepingTrackID: currentTrackID)
            guard playbackQueue.indices.contains(currentQueueIndex),
                  playbackQueue[currentQueueIndex].id == currentTrackID,
                  currentQueueIndex < playbackQueue.count - 1 else {
                return false
            }

            currentQueueIndex += 1
            await playCurrentTrack()
            return true
        } catch {
            context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Station queue refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    private func performQueueOperation(_ operation: @escaping () async throws -> Void) async {
        await flushPendingServerQueueReorderIfNeeded()
        isQueueOperationInProgress = true
        defer { isQueueOperationInProgress = false }

        do {
            try await operation()
        } catch {
            self.context.libraryStore?.libraryLoadError = LibraryLoadError(error)
            logDebug("Play queue operation failed: \(error.localizedDescription)")
        }
    }

    private func setStationContinuationEnabled(_ isEnabled: Bool) {
        isStationContinuationEnabled = isEnabled && continuationMode.isStationBacked
        if isStationContinuationEnabled, let currentTrack {
            prefetchStationQueueLookaheadIfNeeded(for: currentTrack)
        } else {
            stationQueuePrefetchTask?.cancel()
            stationQueuePrefetchTask = nil
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
        prefetchStationQueueLookaheadIfNeeded(for: track)
    }

    private func updatePrebufferedNextTrack() {
        context.playbackEngine?.prebufferNextTrack(nextTrack)
    }

    private func applyOptimisticQueueMove(sourceIndex: Int, targetIndex: Int) {
        let currentTrackID = currentTrack?.id
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        let track = playbackQueue.remove(at: sourceIndex)
        playbackQueue.insert(track, at: min(adjustedTarget, playbackQueue.count))
        orderedPlaybackQueue = playbackQueue
        if let currentTrackID,
           let currentIndex = playbackQueue.firstIndex(where: { $0.id == currentTrackID }) {
            currentQueueIndex = currentIndex
        }
        visiblePlayQueue = playbackQueue
        self.context.libraryStore?.refreshQueueStationRecommendations(for: playbackQueue)
        updatePrebufferedNextTrack()
        queueDidChange?()
    }

    private func scheduleServerQueueReorderSync(playQueueID: Int) {
        queuedServerQueueReorderRevision += 1
        isQueueReorderSyncInProgress = true
        serverQueueReorderTask?.cancel()
        serverQueueReorderTask = Task {
            do {
                try await Task.sleep(nanoseconds: self.serverQueueReorderDebounceNanoseconds)
            } catch {
                return
            }

            await self.flushPendingServerQueueReorderIfNeeded(playQueueID: playQueueID, cancelScheduledTask: false)
        }
    }

    private func flushPendingServerQueueReorderIfNeeded(
        playQueueID: Int? = nil,
        cancelScheduledTask: Bool = true
    ) async {
        if cancelScheduledTask {
            serverQueueReorderTask?.cancel()
            serverQueueReorderTask = nil
        }

        guard queuedServerQueueReorderRevision > syncedServerQueueReorderRevision,
              !isFlushingServerQueueReorder,
              let resolvedPlayQueueID = playQueueID ?? self.playQueueID else {
            isQueueReorderSyncInProgress = queuedServerQueueReorderRevision > syncedServerQueueReorderRevision
            return
        }

        isFlushingServerQueueReorder = true
        isQueueReorderSyncInProgress = true
        defer {
            isFlushingServerQueueReorder = false
            isQueueReorderSyncInProgress = queuedServerQueueReorderRevision > syncedServerQueueReorderRevision
        }

        while queuedServerQueueReorderRevision > syncedServerQueueReorderRevision {
            let targetRevision = queuedServerQueueReorderRevision
            let currentTrackID = currentTrack?.id
            let desiredQueue = playbackQueue

            do {
                let snapshot = try await reconcileServerQueueOrder(
                    playQueueID: resolvedPlayQueueID,
                    desiredQueue: desiredQueue
                )
                syncedServerQueueReorderRevision = targetRevision

                guard currentTrack?.id == currentTrackID,
                      queuedServerQueueReorderRevision == targetRevision else {
                    continue
                }

                applyServerSnapshot(snapshot, keepingTrackID: currentTrackID)
            } catch {
                guard !(error is CancellationError) else {
                    return
                }
                context.libraryStore?.libraryLoadError = LibraryLoadError(error)
                logDebug("Play queue reorder sync failed: \(error.localizedDescription)")

                do {
                    let snapshot = try await context.mediaService.refreshPlayQueue(
                        id: resolvedPlayQueueID,
                        itemCount: max(playQueueTotalCount, playbackQueue.count),
                        centeredOn: currentTrack?.playQueueItemID ?? currentTrack?.id
                    )
                    syncedServerQueueReorderRevision = queuedServerQueueReorderRevision
                    applyServerSnapshot(snapshot, keepingTrackID: currentTrack?.id)
                } catch {
                    guard !(error is CancellationError) else {
                        return
                    }
                    context.libraryStore?.libraryLoadError = LibraryLoadError(error)
                    logDebug("Play queue reorder recovery failed: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func reconcileServerQueueOrder(
        playQueueID: Int,
        desiredQueue: [MediaTrack]
    ) async throws -> PlayQueueSnapshot {
        var latestSnapshot = PlayQueueSnapshot(
            id: playQueueID,
            totalCount: max(playQueueTotalCount, desiredQueue.count),
            selectedTrackID: currentTrack?.id,
            version: playQueueVersion,
            isShuffled: isShuffleEnabled,
            tracks: desiredQueue
        )

        guard let currentTrackID = currentTrack?.id,
              let currentIndex = desiredQueue.firstIndex(where: { $0.id == currentTrackID }),
              currentIndex < desiredQueue.count - 1 else {
            return latestSnapshot
        }

        for index in (currentIndex + 1)..<desiredQueue.count {
            let track = desiredQueue[index]
            let previousTrack = desiredQueue[index - 1]
            latestSnapshot = try await context.mediaService.moveQueueItem(
                playQueueID: playQueueID,
                playQueueItemID: track.playQueueItemID ?? track.id,
                afterPlayQueueItemID: previousTrack.playQueueItemID ?? previousTrack.id,
                itemCount: max(playQueueTotalCount, desiredQueue.count)
            )
        }

        return latestSnapshot
    }

    private func resetPendingServerQueueReorderState() {
        serverQueueReorderTask?.cancel()
        serverQueueReorderTask = nil
        queuedServerQueueReorderRevision = 0
        syncedServerQueueReorderRevision = 0
        isFlushingServerQueueReorder = false
        isQueueReorderSyncInProgress = false
    }

    private func resetPendingQueueOperationState() {
        queuedQueueOperationTask?.cancel()
        queuedQueueOperationTask = nil
    }

    private func prefetchStationQueueLookaheadIfNeeded(for track: MediaTrack) {
        guard canContinueStationQueueFromTail,
              let playQueueID else {
            stationQueuePrefetchTask?.cancel()
            stationQueuePrefetchTask = nil
            return
        }

        let currentTrackID = track.id
        let centeredOnItemID = track.playQueueItemID ?? track.id
        stationQueuePrefetchTask?.cancel()
        stationQueuePrefetchTask = Task {
            do {
                let snapshot = try await self.context.mediaService.refreshPlayQueue(
                    id: playQueueID,
                    itemCount: max(self.playQueueTotalCount, self.playbackQueue.count) + self.stationContinuationLookaheadCount,
                    centeredOn: centeredOnItemID
                )
                guard !Task.isCancelled,
                      self.currentTrack?.id == currentTrackID,
                      self.playbackQueue.indices.contains(self.currentQueueIndex),
                      self.currentQueueIndex == self.playbackQueue.count - 1,
                      snapshot.tracks.contains(where: { $0.id == currentTrackID }) else {
                    return
                }

                self.applyServerSnapshot(snapshot, keepingTrackID: currentTrackID)
            } catch {
                guard !Task.isCancelled else { return }
                self.logDebug("Station queue prefetch failed: \(error.localizedDescription)")
            }

            if !Task.isCancelled {
                self.stationQueuePrefetchTask = nil
            }
        }
    }

    private func logDebug(_ message: String) {
        PlexLog.debug(message, category: .queue)
    }
}
