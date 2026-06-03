import Foundation

@MainActor
protocol MediaService: AnyObject {
    var isAuthenticated: Bool { get }
    var authenticatedUsername: String? { get }
    var authToken: String? { get }

    // Auth
    func signIn() async throws
    var authPinCode: String? { get }
    var authError: String? { get }

    // Server & Library
    var availableServers: [MediaServer] { get }
    var selectedServerID: String? { get set }
    var availableLibraries: [MediaMusicLibrary] { get }
    var selectedLibraryID: String? { get set }

    func refreshServers() async throws
    func refreshLibraries() async throws

    // Content
    func fetchHomeContent(limit: Int) async throws -> MediaHomeContent
    func fetchAlbumTracks(albumID: String) async throws -> [MediaTrack]
    func fetchRelatedAlbums(albumRatingKey: String, limit: Int) async throws -> [MediaAlbum]
    func fetchPlaylistTracks(playlistID: String) async throws -> [MediaTrack]
    func fetchLastPlayedTrack() async throws -> MediaTrack?

    // Play queue
    var supportsServerManagedQueue: Bool { get }
    func createPlaylistPlayQueue(playlistID: String, shuffle: Bool) async throws -> PlayQueueSnapshot
    func createStationPlayQueue(stationKey: String) async throws -> PlayQueueSnapshot
    func createAlbumPlayQueue(albumID: String, startingTrackRatingKey: String, shuffle: Bool) async throws -> PlayQueueSnapshot
    func shufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot
    func unshufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot
    func refreshPlayQueue(id: Int, itemCount: Int, centeredOn playQueueItemID: String?) async throws -> PlayQueueSnapshot
    func addAlbumToQueue(albumID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot
    func addPlaylistToQueue(playlistID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot
    func addStationToQueue(stationKey: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot
    func removeQueueItem(playQueueID: Int, playQueueItemID: String, itemCount: Int) async throws -> PlayQueueSnapshot
    func clearQueue(playQueueID: Int) async throws
    func moveQueueItem(playQueueID: Int, playQueueItemID: String, afterPlayQueueItemID: String?, itemCount: Int) async throws -> PlayQueueSnapshot

    // Playback
    func streamURL(from path: String) -> URL
    func artworkURL(from path: String?) -> URL?
    func fetchLoudnessGain(ratingKey: String) async throws -> Float?

    // Timeline
    func reportPlaybackTimeline(ratingKey: String, playQueueID: Int?, playQueueItemID: String?, state: PlaybackState, positionMilliseconds: Int, durationMilliseconds: Int) async throws
    func markTrackListened(ratingKey: String) async throws
}
