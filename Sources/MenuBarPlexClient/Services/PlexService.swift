import Foundation

@MainActor
final class PlexService: MediaService {
    // MARK: - Dependencies
    private let networkClient: PlexNetworkClient
    private let discovery: PlexServerDiscoveryService
    private let content: PlexContentService
    private let queue: PlexPlayQueueService
    private let timeline: PlexTimelineService
    private let loudness: PlexLoudnessService
    let authService: PlexAuthService

    // MARK: - Auth state

    var isAuthenticated: Bool { authService.authToken != nil }
    var authenticatedUsername: String? {
        guard case let .authenticated(username) = authService.status.state else { return nil }
        return username
    }
    var authPinCode: String? {
        guard case let .waitingForBrowserLogin(_, code) = authService.status.state else { return nil }
        return code
    }
    var authError: String? {
        guard case let .failed(message) = authService.status.state else { return nil }
        return message
    }

    // MARK: - Server & Library state

    private var _selectedServer: PlexServer?
    private var _selectedLibrary: PlexMusicLibrary?

    var availableServers: [MediaServer] = []
    var selectedServerID: String? {
        didSet {
            guard let id = selectedServerID,
                  let plex = plexServers.first(where: { $0.id == id }) else {
                _selectedServer = nil
                return
            }
            _selectedServer = plex
        }
    }

    var availableLibraries: [MediaMusicLibrary] = []
    var selectedLibraryID: String? {
        didSet {
            guard let id = selectedLibraryID,
                  let plex = plexLibraries.first(where: { $0.id == id }) else {
                _selectedLibrary = nil
                return
            }
            _selectedLibrary = plex
        }
    }

    private var plexServers: [PlexServer] = []
    private var plexLibraries: [PlexMusicLibrary] = []

    // MARK: - Init

    init(session: URLSession = .shared, authService: PlexAuthService? = nil) {
        let networkClient = PlexNetworkClient(session: session)
        self.networkClient = networkClient
        self.discovery = PlexServerDiscoveryService(client: networkClient)
        self.content = PlexContentService(client: networkClient)
        self.queue = PlexPlayQueueService(client: networkClient, content: content)
        self.timeline = PlexTimelineService(client: networkClient)
        self.loudness = PlexLoudnessService(client: networkClient)
        self.authService = authService ?? PlexAuthService(session: session)
    }

    // MARK: - Auth

    func signIn() async throws {
        await authService.beginLogin()
    }

    // MARK: - Server & Library

    func refreshServers() async throws {
        guard let token = authService.authToken else { return }
        plexServers = try await discovery.fetchServers(userToken: token)
        availableServers = plexServers.map(\.mediaServer)
    }

    func refreshLibraries() async throws {
        guard let server = _selectedServer, let token = authService.authToken else { return }
        plexLibraries = try await discovery.fetchMusicLibraries(server: server, userToken: token)
        availableLibraries = plexLibraries.map(\.mediaMusicLibrary)
    }

    // MARK: - Content

    func fetchHomeContent(limit: Int) async throws -> MediaHomeContent {
        guard let server = _selectedServer, let library = _selectedLibrary, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let result = try await content.fetchHomeContent(
            server: server, library: library, userToken: token, limit: limit
        )
        return result.mediaHomeContent
    }

    func fetchAlbumTracks(albumID: String) async throws -> [MediaTrack] {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let plexAlbum = PlexAlbum(id: albumID, title: "", artist: "", artworkURL: nil)
        let tracks = try await content.fetchAlbumTracks(server: server, album: plexAlbum, userToken: token)
        return tracks.map(\.mediaTrack)
    }

    func fetchRelatedAlbums(albumRatingKey: String, limit: Int) async throws -> [MediaAlbum] {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let albums = try await content.fetchRelatedAlbums(
            server: server, albumRatingKey: albumRatingKey, userToken: token, limit: limit
        )
        return albums.map(\.mediaAlbum)
    }

    func fetchPlaylistTracks(playlistID: String) async throws -> [MediaTrack] {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let plexPlaylist = PlexPlaylist(id: playlistID, title: "", trackCount: 0)
        let tracks = try await content.fetchPlaylistTracks(
            server: server, playlist: plexPlaylist, userToken: token
        )
        return tracks.map(\.mediaTrack)
    }

    func fetchLastPlayedTrack() async throws -> MediaTrack? {
        guard let server = _selectedServer, let library = _selectedLibrary, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let track = try await content.fetchLastPlayedTrack(
            server: server, library: library, userToken: token
        )
        return track?.mediaTrack
    }

    // MARK: - Play queue

    var supportsServerManagedQueue: Bool { true }

    func createPlaylistPlayQueue(playlistID: String, shuffle: Bool) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let plexPlaylist = PlexPlaylist(id: playlistID, title: "", trackCount: 0)
        let snapshot = try await queue.createPlaylistPlayQueue(
            server: server, playlist: plexPlaylist, userToken: token, shuffle: shuffle
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func createStationPlayQueue(stationKey: String) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let station = PlexStation(id: stationKey, title: "", key: stationKey)
        let snapshot = try await queue.createStationPlayQueue(
            server: server, station: station, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func createAlbumPlayQueue(albumID: String, startingTrackRatingKey: String, shuffle: Bool) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let library = _selectedLibrary, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let album = PlexAlbum(id: albumID, title: "", artist: "", artworkURL: nil)
        let snapshot = try await queue.createAlbumPlayQueue(
            server: server, library: library, album: album,
            startingTrackRatingKey: startingTrackRatingKey, userToken: token, shuffle: shuffle
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func shufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let snapshot = try await queue.shufflePlayQueue(
            server: server, playQueueID: id, itemCount: 1, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func unshufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let snapshot = try await queue.unshufflePlayQueue(
            server: server, playQueueID: id, itemCount: 1, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func refreshPlayQueue(id: Int, itemCount: Int, centeredOn playQueueItemID: String?) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let snapshot = try await queue.refreshPlayQueue(
            server: server, playQueueID: id, itemCount: itemCount,
            centeredOn: playQueueItemID, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func addAlbumToQueue(albumID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let library = _selectedLibrary, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let album = PlexAlbum(id: albumID, title: "", artist: "", artworkURL: nil)
        let snapshot = try await queue.addAlbumToPlayQueue(
            server: server, library: library, album: album,
            playQueueID: playQueueID, playNext: playNext, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func addPlaylistToQueue(playlistID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let playlist = PlexPlaylist(id: playlistID, title: "", trackCount: 0)
        let snapshot = try await queue.addPlaylistToPlayQueue(
            server: server, playlist: playlist,
            playQueueID: playQueueID, playNext: playNext, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func addStationToQueue(stationKey: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let station = PlexStation(id: stationKey, title: "", key: stationKey)
        let snapshot = try await queue.addStationToPlayQueue(
            server: server, station: station,
            playQueueID: playQueueID, playNext: playNext, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func removeQueueItem(playQueueID: Int, playQueueItemID: String, itemCount: Int) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let snapshot = try await queue.removePlayQueueItem(
            server: server, playQueueID: playQueueID,
            playQueueItemID: playQueueItemID, itemCount: itemCount, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    func clearQueue(playQueueID: Int) async throws {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        try await queue.clearPlayQueue(server: server, playQueueID: playQueueID, userToken: token)
    }

    func moveQueueItem(playQueueID: Int, playQueueItemID: String, afterPlayQueueItemID: String?, itemCount: Int) async throws -> PlayQueueSnapshot {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        let snapshot = try await queue.movePlayQueueItem(
            server: server, playQueueID: playQueueID,
            playQueueItemID: playQueueItemID, afterPlayQueueItemID: afterPlayQueueItemID,
            itemCount: itemCount, userToken: token
        )
        return snapshot.mediaPlayQueueSnapshot
    }

    // MARK: - Playback

    func streamURL(from path: String) -> URL {
        guard let server = _selectedServer else { return URL(string: "about:blank")! }
        return plexStreamURL(from: path, server: server, token: authService.authToken)
    }

    func artworkURL(from path: String?) -> URL? {
        guard let server = _selectedServer else { return nil }
        return plexArtworkURL(from: path, server: server, token: authService.authToken)
    }

    func fetchLoudnessGain(ratingKey: String) async throws -> Float? {
        guard let server = _selectedServer, let token = authService.authToken else {
            return nil
        }
        return try await loudness.fetchLoudnessGain(
            server: server, ratingKey: ratingKey, userToken: token
        )
    }

    // MARK: - Timeline

    func reportPlaybackTimeline(ratingKey: String, playQueueID: Int?, playQueueItemID: String?, state: PlaybackState, positionMilliseconds: Int, durationMilliseconds: Int) async throws {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        try await timeline.reportPlaybackTimeline(
            server: server, ratingKey: ratingKey,
            playQueueID: playQueueID, playQueueItemID: playQueueItemID,
            state: state, positionMilliseconds: positionMilliseconds,
            durationMilliseconds: durationMilliseconds, userToken: token
        )
    }

    func markTrackListened(ratingKey: String) async throws {
        guard let server = _selectedServer, let token = authService.authToken else {
            throw PlexAPIError.serverSelectionRequired
        }
        try await timeline.markTrackListened(
            server: server, ratingKey: ratingKey, userToken: token
        )
    }

    // MARK: - PlexAPIClient compatibility (delegates to sub-services)

    func fetchServers(userToken: String) async throws -> [PlexServer] {
        try await discovery.fetchServers(userToken: userToken)
    }

    func fetchMusicLibraries(server: PlexServer, userToken: String) async throws -> [PlexMusicLibrary] {
        try await discovery.fetchMusicLibraries(server: server, userToken: userToken)
    }

    func fetchHomeContent(server: PlexServer, library: PlexMusicLibrary, userToken: String, limit: Int = 12) async throws -> PlexHomeContent {
        try await content.fetchHomeContent(server: server, library: library, userToken: userToken, limit: limit)
    }

    func fetchAlbumTracks(server: PlexServer, album: PlexAlbum, userToken: String) async throws -> [PlexTrack] {
        try await content.fetchAlbumTracks(server: server, album: album, userToken: userToken)
    }

    func fetchRelatedAlbums(server: PlexServer, albumRatingKey: String, userToken: String, limit: Int = 3) async throws -> [PlexAlbum] {
        try await content.fetchRelatedAlbums(server: server, albumRatingKey: albumRatingKey, userToken: userToken, limit: limit)
    }

    func fetchPlaylistTracks(server: PlexServer, playlist: PlexPlaylist, userToken: String) async throws -> [PlexTrack] {
        try await content.fetchPlaylistTracks(server: server, playlist: playlist, userToken: userToken)
    }

    func fetchLastPlayedTrack(server: PlexServer, library: PlexMusicLibrary, userToken: String) async throws -> PlexTrack? {
        try await content.fetchLastPlayedTrack(server: server, library: library, userToken: userToken)
    }

    func createPlaylistPlayQueue(server: PlexServer, playlist: PlexPlaylist, userToken: String, shuffle: Bool) async throws -> PlexPlayQueueSnapshot {
        try await queue.createPlaylistPlayQueue(server: server, playlist: playlist, userToken: userToken, shuffle: shuffle)
    }

    func createStationPlayQueue(server: PlexServer, station: PlexStation, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.createStationPlayQueue(server: server, station: station, userToken: userToken)
    }

    func createAlbumPlayQueue(server: PlexServer, library: PlexMusicLibrary, album: PlexAlbum, startingTrackRatingKey: String, userToken: String, shuffle: Bool) async throws -> PlexPlayQueueSnapshot {
        try await queue.createAlbumPlayQueue(server: server, library: library, album: album, startingTrackRatingKey: startingTrackRatingKey, userToken: userToken, shuffle: shuffle)
    }

    func shufflePlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.shufflePlayQueue(server: server, playQueueID: playQueueID, itemCount: itemCount, userToken: userToken)
    }

    func unshufflePlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.unshufflePlayQueue(server: server, playQueueID: playQueueID, itemCount: itemCount, userToken: userToken)
    }

    func refreshPlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, centeredOn playQueueItemID: String? = nil, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.refreshPlayQueue(server: server, playQueueID: playQueueID, itemCount: itemCount, centeredOn: playQueueItemID, userToken: userToken)
    }

    func addAlbumToPlayQueue(server: PlexServer, library: PlexMusicLibrary, album: PlexAlbum, playQueueID: Int, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.addAlbumToPlayQueue(server: server, library: library, album: album, playQueueID: playQueueID, playNext: playNext, userToken: userToken)
    }

    func addPlaylistToPlayQueue(server: PlexServer, playlist: PlexPlaylist, playQueueID: Int, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.addPlaylistToPlayQueue(server: server, playlist: playlist, playQueueID: playQueueID, playNext: playNext, userToken: userToken)
    }

    func addStationToPlayQueue(server: PlexServer, station: PlexStation, playQueueID: Int, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.addStationToPlayQueue(server: server, station: station, playQueueID: playQueueID, playNext: playNext, userToken: userToken)
    }

    func removePlayQueueItem(server: PlexServer, playQueueID: Int, playQueueItemID: String, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.removePlayQueueItem(server: server, playQueueID: playQueueID, playQueueItemID: playQueueItemID, itemCount: itemCount, userToken: userToken)
    }

    func clearPlayQueue(server: PlexServer, playQueueID: Int, userToken: String) async throws {
        try await queue.clearPlayQueue(server: server, playQueueID: playQueueID, userToken: userToken)
    }

    func movePlayQueueItem(server: PlexServer, playQueueID: Int, playQueueItemID: String, afterPlayQueueItemID: String?, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await queue.movePlayQueueItem(server: server, playQueueID: playQueueID, playQueueItemID: playQueueItemID, afterPlayQueueItemID: afterPlayQueueItemID, itemCount: itemCount, userToken: userToken)
    }

    func reportPlaybackTimeline(server: PlexServer, ratingKey: String, playQueueID: Int?, playQueueItemID: String?, state: PlaybackState, positionMilliseconds: Int, durationMilliseconds: Int, userToken: String) async throws {
        try await timeline.reportPlaybackTimeline(server: server, ratingKey: ratingKey, playQueueID: playQueueID, playQueueItemID: playQueueItemID, state: state, positionMilliseconds: positionMilliseconds, durationMilliseconds: durationMilliseconds, userToken: userToken)
    }

    func markTrackListened(server: PlexServer, ratingKey: String, userToken: String) async throws {
        try await timeline.markTrackListened(server: server, ratingKey: ratingKey, userToken: userToken)
    }

    func fetchLoudnessGain(server: PlexServer, ratingKey: String, userToken: String) async throws -> Float? {
        try await loudness.fetchLoudnessGain(server: server, ratingKey: ratingKey, userToken: userToken)
    }
}
