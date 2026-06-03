import Foundation

@MainActor
final class LocalService: MediaService {
    var availableServers: [MediaServer] = [
        MediaServer(id: "local", name: "Local Files", accessToken: nil, baseURL: URL(string: "file:///")!)
    ]
    var selectedServerID: String? = "local"
    var availableLibraries: [MediaMusicLibrary] = [
        MediaMusicLibrary(id: "local", title: "Files", uuid: nil)
    ]
    var selectedLibraryID: String? = "local"

    var isAuthenticated: Bool { true }
    var authenticatedUsername: String? { nil }
    var authToken: String? { nil }

    func signIn() async throws {}
    var authPinCode: String? { nil }
    var authError: String? { nil }

    func refreshServers() async throws {}
    func refreshLibraries() async throws {}

    func fetchHomeContent(limit: Int) async throws -> MediaHomeContent {
        MediaHomeContent(recentlyPlayedAlbums: [], recentlyAddedAlbums: [], playlists: [], stations: [])
    }

    func fetchAlbumTracks(albumID: String) async throws -> [MediaTrack] {
        throw LocalServiceError.notSupported("Albums not supported in local mode")
    }

    func fetchRelatedAlbums(albumRatingKey: String, limit: Int) async throws -> [MediaAlbum] {
        []
    }

    func fetchPlaylistTracks(playlistID: String) async throws -> [MediaTrack] {
        throw LocalServiceError.notSupported("Playlists not supported in local mode")
    }

    func fetchLastPlayedTrack() async throws -> MediaTrack? {
        nil
    }

    func searchLibrary(query: String, limit: Int) async throws -> MediaSearchResults {
        MediaSearchResults(tracks: [], albums: [])
    }

    var supportsServerManagedQueue: Bool { false }

    func createPlaylistPlayQueue(playlistID: String, shuffle: Bool) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func createStationPlayQueue(stationKey: String) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func createAlbumPlayQueue(albumID: String, startingTrackRatingKey: String, shuffle: Bool) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func shufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func unshufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func refreshPlayQueue(id: Int, itemCount: Int, centeredOn playQueueItemID: String?) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func addAlbumToQueue(albumID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func addPlaylistToQueue(playlistID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func addStationToQueue(stationKey: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func createTrackListPlayQueue(tracks: [MediaTrack]) async throws -> PlayQueueSnapshot {
        guard !tracks.isEmpty else { throw LocalServiceError.notSupported("No tracks provided") }
        return PlayQueueSnapshot(
            id: 0,
            totalCount: tracks.count,
            selectedTrackID: tracks.first?.id,
            version: nil,
            isShuffled: false,
            tracks: tracks
        )
    }

    func addTracksToQueue(tracks: [MediaTrack], playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func removeQueueItem(playQueueID: Int, playQueueItemID: String, itemCount: Int) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func clearQueue(playQueueID: Int) async throws {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func moveQueueItem(playQueueID: Int, playQueueItemID: String, afterPlayQueueItemID: String?, itemCount: Int) async throws -> PlayQueueSnapshot {
        throw LocalServiceError.notSupported("Server-managed queue not supported")
    }

    func streamURL(from path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    func artworkURL(from path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix("file://") || path.hasPrefix("/") {
            return URL(fileURLWithPath: path.hasPrefix("file://") ? String(path.dropFirst(7)) : path)
        }
        return URL(string: path)
    }

    func fetchLoudnessGain(ratingKey: String) async throws -> Float? {
        nil
    }

    func reportPlaybackTimeline(ratingKey: String, playQueueID: Int?, playQueueItemID: String?, state: PlaybackState, positionMilliseconds: Int, durationMilliseconds: Int) async throws {
    }

    func markTrackListened(ratingKey: String) async throws {
    }
}

enum LocalServiceError: Error {
    case notSupported(String)
}

extension LocalServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notSupported(let message): return message
        }
    }
}
