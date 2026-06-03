import Foundation

@MainActor
final class NavidromeService: MediaService {
    let client: SubsonicClient

    var availableServers: [MediaServer] = []
    var selectedServerID: String?
    var availableLibraries: [MediaMusicLibrary] = []
    var selectedLibraryID: String?

    init(config: NavidromeServerConfig, password: String, session: URLSession = .shared) {
        let baseURLString = config.publicUrl ?? config.url
        let baseURL = URL(string: baseURLString) ?? URL(string: config.url)!
        client = SubsonicClient(baseURL: baseURL, username: config.username, password: password, session: session)
        availableServers = [MediaServer(
            id: config.name,
            name: config.name,
            accessToken: nil,
            baseURL: baseURL
        )]
        availableLibraries = [MediaMusicLibrary(id: "default", title: "Music", uuid: nil)]
        selectedServerID = config.name
        selectedLibraryID = "default"
    }

    var isAuthenticated: Bool { true }

    var authenticatedUsername: String? { nil }

    var authToken: String? { nil }

    func signIn() async throws {}

    var authPinCode: String? { nil }

    var authError: String? { nil }

    func refreshServers() async throws {}

    func refreshLibraries() async throws {}

    func fetchHomeContent(limit: Int) async throws -> MediaHomeContent {
        let newest = try await client.getAlbumList(type: "newest", offset: 0, size: limit)
        let recent = try await client.getAlbumList(type: "recent", offset: 0, size: limit)
        let playlists = try await client.getPlaylists()
        let genres = (try? await client.getGenres()) ?? []
        return MediaHomeContent(
            recentlyPlayedAlbums: recent.map { $0.mediaAlbum(client: client) },
            recentlyAddedAlbums: newest.map { $0.mediaAlbum(client: client) },
            playlists: playlists.map(\.mediaPlaylist),
            stations: genres
                .filter { !$0.name.isEmpty && ($0.songCount ?? 0) > 0 }
                .prefix(limit)
                .map(\.mediaStation)
        )
    }

    func fetchAlbumTracks(albumID: String) async throws -> [MediaTrack] {
        let detail = try await client.getAlbum(id: albumID)
        return (detail.song ?? []).map { $0.mediaTrack(client: client) }
    }

    func fetchRelatedAlbums(albumRatingKey: String, limit: Int) async throws -> [MediaAlbum] {
        return []
    }

    func fetchPlaylistTracks(playlistID: String) async throws -> [MediaTrack] {
        let entries = try await client.getPlaylist(id: playlistID)
        return entries.map { $0.mediaTrack(client: client) }
    }

    func fetchLastPlayedTrack() async throws -> MediaTrack? {
        let albums = try await client.getAlbumList(type: "recent", offset: 0, size: 1)
        guard let album = albums.first else { return nil }
        let detail = try await client.getAlbum(id: album.id)
        return (detail.song ?? []).first?.mediaTrack(client: client)
    }

    func searchLibrary(query: String, limit: Int) async throws -> MediaSearchResults {
        let result = try await client.search(query: query, limit: limit)
        var tracks = (result.song ?? []).map { $0.mediaTrack(client: client) }
        var albums = (result.album ?? []).map { $0.mediaAlbum(client: client) }

        for artist in result.artist ?? [] {
            guard let detail = try? await client.getArtist(id: artist.id) else { continue }
            let artistAlbums = detail.album ?? []
            albums.append(contentsOf: artistAlbums.map { $0.mediaAlbum(client: client) })

            for album in artistAlbums where tracks.count < limit {
                guard let detail = try? await client.getAlbum(id: album.id) else { continue }
                tracks.append(contentsOf: (detail.song ?? []).map { $0.mediaTrack(client: client) })
            }
        }

        return MediaSearchResults(
            tracks: deduplicate(tracks).prefix(limit).map { $0 },
            albums: deduplicate(albums).prefix(limit).map { $0 }
        )
    }

    var supportsServerManagedQueue: Bool { false }

    func createPlaylistPlayQueue(playlistID: String, shuffle: Bool) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func createStationPlayQueue(stationKey: String) async throws -> PlayQueueSnapshot {
        let tracks = try await fetchGenreTracks(genre: stationKey)
        guard !tracks.isEmpty else {
            throw NavidromeError.notFound
        }

        return PlayQueueSnapshot(
            id: 0,
            totalCount: tracks.count,
            selectedTrackID: tracks.first?.id,
            version: nil,
            isShuffled: false,
            tracks: tracks
        )
    }

    func createAlbumPlayQueue(albumID: String, startingTrackRatingKey: String, shuffle: Bool) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func shufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func unshufflePlayQueue(id: Int) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func refreshPlayQueue(id: Int, itemCount: Int, centeredOn playQueueItemID: String?) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func addAlbumToQueue(albumID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func addPlaylistToQueue(playlistID: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func addStationToQueue(stationKey: String, playQueueID: Int, playNext: Bool) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Stations not supported by Navidrome")
    }

    func createTrackListPlayQueue(tracks: [MediaTrack]) async throws -> PlayQueueSnapshot {
        guard !tracks.isEmpty else {
            throw NavidromeError.notFound
        }

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
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func removeQueueItem(playQueueID: Int, playQueueItemID: String, itemCount: Int) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func clearQueue(playQueueID: Int) async throws {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func moveQueueItem(playQueueID: Int, playQueueItemID: String, afterPlayQueueItemID: String?, itemCount: Int) async throws -> PlayQueueSnapshot {
        throw NavidromeError.notSupported("Server-managed play queue not supported by Navidrome")
    }

    func streamURL(from path: String) -> URL {
        client.streamURL(id: path)
    }

    func artworkURL(from path: String?) -> URL? {
        guard let path else { return nil }
        return client.coverArtURL(id: path)
    }

    func fetchLoudnessGain(ratingKey: String) async throws -> Float? {
        let song = try await client.getSong(id: ratingKey)
        return song.replayGain?.trackGain.map { Float($0) }
    }

    func fetchGenreTracks(genre: String) async throws -> [MediaTrack] {
        let tracks = try await client.getSongsByGenre(genre: genre)
        return tracks.map { $0.mediaTrack(client: client) }
    }

    func reportPlaybackTimeline(ratingKey: String, playQueueID: Int?, playQueueItemID: String?, state: PlaybackState, positionMilliseconds: Int, durationMilliseconds: Int) async throws {
        try await client.scrobble(id: ratingKey, submission: false)
    }

    func markTrackListened(ratingKey: String) async throws {
        try await client.scrobble(id: ratingKey, submission: true)
    }
}

private extension SubsonicAlbum {
    func artworkURL(client: SubsonicClient) -> URL? {
        coverArt.map { client.coverArtURL(id: $0) }
    }

    var mediaAlbum: MediaAlbum {
        MediaAlbum(id: id, title: name, artist: artist ?? "Unknown Artist", artworkURL: nil)
    }

    func mediaAlbum(client: SubsonicClient) -> MediaAlbum {
        MediaAlbum(id: id, title: name, artist: artist ?? "Unknown Artist", artworkURL: artworkURL(client: client))
    }
}

private extension SubsonicGenre {
    var mediaStation: MediaStation {
        MediaStation(id: "genre-\(name)", title: name, key: name)
    }
}

private extension SubsonicTrack {
    func artworkURL(client: SubsonicClient) -> URL? {
        coverArt.map { client.coverArtURL(id: $0) }
    }

    func mediaTrack(client: SubsonicClient) -> MediaTrack {
        MediaTrack(
            id: id,
            playQueueItemID: nil,
            ratingKey: id,
            albumRatingKey: albumId,
            artistRatingKey: nil,
            durationMilliseconds: duration.map { $0 * 1000 },
            title: title,
            trackArtist: artist,
            albumArtist: nil,
            albumName: album ?? "Unknown Album",
            artworkURL: artworkURL(client: client),
            trackNumber: track,
            discNumber: discNumber,
            streamURL: client.streamURL(id: id)
        )
    }
}

private extension SubsonicPlaylist {
    var mediaPlaylist: MediaPlaylist {
        MediaPlaylist(id: id, title: name, trackCount: songCount ?? 0)
    }
}
