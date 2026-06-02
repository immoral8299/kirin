import Foundation

enum PlexAPIError: LocalizedError {
    case invalidResponse
    case unsupportedResponseFormat
    case noReachableServer
    case noTracksInLibrary
    case serverSelectionRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Plex returned an invalid response."
        case .unsupportedResponseFormat:
            return "Plex response format is unsupported."
        case .noReachableServer:
            return "No reachable Plex server connection was found."
        case .noTracksInLibrary:
            return "No playable tracks were found in this library."
        case .serverSelectionRequired:
            return "Select a Plex server in settings to continue."
        }
    }
}

struct PlexAPIClient {
    private let session: URLSession
    private let clientIdentifier = "plextray"
    private let productName = "PlexTray"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchServers(userToken: String) async throws -> [PlexServer] {
        guard let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1") else {
            throw URLError(.badURL)
        }

        let data = try await request(url: url, token: userToken)
        let resources = try resourceArray(from: data)

        var servers: [PlexServer] = []

        for resource in resources {
            guard let provides = resource.string(for: ["provides"]),
                  provides.contains("server") else {
                continue
            }

            guard let id = resource.string(for: ["clientIdentifier", "machineIdentifier", "identifier"]),
                  let name = resource.string(for: ["name", "device", "sourceTitle"]) else {
                continue
            }

            let token = resource.string(for: ["accessToken"])
            let connections = resource.objectArray(for: ["connections", "Connection"])
            guard let baseURL = bestConnectionURL(from: connections) else {
                continue
            }

            servers.append(
                PlexServer(
                    id: id,
                    name: name,
                    accessToken: token,
                    baseURL: baseURL
                )
            )
        }

        let deduplicated = Dictionary(grouping: servers, by: \.id).compactMap { $0.value.first }
        return deduplicated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchMusicLibraries(server: PlexServer, userToken: String) async throws -> [PlexMusicLibrary] {
        let token = server.accessToken ?? userToken
        let url = buildURL(base: server.baseURL, path: "library/sections")
        let data = try await request(url: url, token: token)
        let container = try mediaContainer(from: data)
        let directories = container.objectArray(for: ["Directory", "directory"])

        let libraries = directories.compactMap { directory -> PlexMusicLibrary? in
            guard let type = directory.string(for: ["type"])?.lowercased(), type == "artist" else {
                return nil
            }

            guard let id = directory.string(for: ["key"]),
                  let title = directory.string(for: ["title"]) else {
                return nil
            }

            return PlexMusicLibrary(id: id, title: title, uuid: directory.string(for: ["uuid"]))
        }

        return libraries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func fetchHomeContent(server: PlexServer, library: PlexMusicLibrary, userToken: String, limit: Int = 12) async throws -> PlexHomeContent {
        let token = server.accessToken ?? userToken
        let pageQuery = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
        ]

        let recentlyViewedURL = buildURL(
            base: server.baseURL,
            path: "library/sections/\(library.id)/recentlyViewed",
            query: [URLQueryItem(name: "type", value: "9")] + pageQuery
        )

        let recentlyAddedURL = buildURL(
            base: server.baseURL,
            path: "library/sections/\(library.id)/recentlyAdded",
            query: [URLQueryItem(name: "type", value: "9")] + pageQuery
        )

        let playlistsURL = buildURL(
            base: server.baseURL,
            path: "playlists",
            query: [
                URLQueryItem(name: "playlistType", value: "audio"),
                URLQueryItem(name: "includeCollections", value: "0"),
            ] + pageQuery
        )

        let stationsURL = buildURL(
            base: server.baseURL,
            path: "hubs/sections/\(library.id)",
            query: [
                URLQueryItem(name: "includeStations", value: "1"),
                URLQueryItem(name: "includeStationDirectories", value: "1"),
            ]
        )

        async let recentlyViewedData = request(url: recentlyViewedURL, token: token)
        async let recentlyAddedData = request(url: recentlyAddedURL, token: token)
        async let playlistsData = request(url: playlistsURL, token: token)
        async let stationsData = request(url: stationsURL, token: token)

        let recentlyPlayedAlbums = try parseAlbums(data: try await recentlyViewedData, server: server, token: token)
        let recentlyAddedAlbums = try parseAlbums(data: try await recentlyAddedData, server: server, token: token)
        let playlists = try parsePlaylists(data: try await playlistsData)
        let stations = (try? parseStations(data: try await stationsData)) ?? []

        return PlexHomeContent(
            recentlyPlayedAlbums: recentlyPlayedAlbums,
            recentlyAddedAlbums: recentlyAddedAlbums,
            playlists: playlists,
            stations: stations
        )
    }

    func fetchLastPlayedTrack(server: PlexServer, library: PlexMusicLibrary, userToken: String) async throws -> PlexTrack? {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "type", value: "10"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "1"),
        ]

        let url = buildURL(base: server.baseURL, path: "library/sections/\(library.id)/recentlyViewed", query: query)
        let data = try await request(url: url, token: token)
        return try parseTracks(data: data, server: server, token: token).first
    }

    func fetchAlbumTracks(server: PlexServer, album: PlexAlbum, userToken: String) async throws -> [PlexTrack] {
        let token = server.accessToken ?? userToken
        let url = buildURL(base: server.baseURL, path: "library/metadata/\(album.id)/children")
        let data = try await request(url: url, token: token)

        let tracks = try parseTracks(data: data, server: server, token: token)
        guard !tracks.isEmpty else {
            throw PlexAPIError.noTracksInLibrary
        }

        return tracks
    }

    func fetchRelatedAlbums(server: PlexServer, albumRatingKey: String, userToken: String, limit: Int = 3) async throws -> [PlexAlbum] {
        let token = server.accessToken ?? userToken
        let query = [URLQueryItem(name: "count", value: String(limit))]
        let url = buildURL(base: server.baseURL, path: "hubs/metadata/\(albumRatingKey)", query: query)
        let data = try await request(url: url, token: token)
        let container = try mediaContainer(from: data)

        return deduplicate(nestedObjects(in: container).compactMap { node -> PlexAlbum? in
            guard node.string(for: ["ratingKey"]) != nil else { return nil }
            return album(from: node, server: server, token: token)
        })
            .filter { $0.id != albumRatingKey }
            .prefix(limit)
            .map { $0 }
    }

    func fetchPlaylistTracks(server: PlexServer, playlist: PlexPlaylist, userToken: String) async throws -> [PlexTrack] {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "playlistType", value: "audio"),
            URLQueryItem(name: "includeCollections", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "200"),
        ]

        let url = buildURL(base: server.baseURL, path: "playlists/\(playlist.id)/items", query: query)
        let data = try await request(url: url, token: token)

        let tracks = try parseTracks(data: data, server: server, token: token)
        guard !tracks.isEmpty else {
            throw PlexAPIError.noTracksInLibrary
        }

        return tracks
    }

    func createPlaylistPlayQueue(server: PlexServer, playlist: PlexPlaylist, userToken: String, shuffle: Bool) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "playlistID", value: playlist.id),
            URLQueryItem(name: "type", value: "audio"),
            URLQueryItem(name: "shuffle", value: shuffle ? "1" : "0"),
        ]

        let url = buildURL(base: server.baseURL, path: "playQueues", query: query)
        let container = try await requestContainer(url: url, token: token, method: "POST")
        guard let playQueueID = container.int(for: ["playQueueID"]) else {
            throw PlexAPIError.invalidResponse
        }

        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? playlist.trackCount, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func createStationPlayQueue(server: PlexServer, station: PlexStation, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "uri", value: "server://\(server.id)/com.plexapp.plugins.library\(station.key)"),
            URLQueryItem(name: "type", value: "audio"),
        ]

        let url = buildURL(base: server.baseURL, path: "playQueues", query: query)
        let container = try await requestContainer(url: url, token: token, method: "POST")
        guard let playQueueID = container.int(for: ["playQueueID"]) else {
            throw PlexAPIError.invalidResponse
        }

        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? 1, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func createAlbumPlayQueue(server: PlexServer, library: PlexMusicLibrary, album: PlexAlbum, startingTrackRatingKey: String, userToken: String, shuffle: Bool) async throws -> PlexPlayQueueSnapshot {
        guard let libraryUUID = library.uuid else {
            throw PlexAPIError.invalidResponse
        }

        let token = server.accessToken ?? userToken
        let albumPath = "/library/metadata/\(album.id)"
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/")
        let encodedAlbumPath = albumPath.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? albumPath
        let query = [
            URLQueryItem(name: "uri", value: "library://\(libraryUUID)/item/\(encodedAlbumPath)"),
            URLQueryItem(name: "type", value: "audio"),
            URLQueryItem(name: "key", value: "/library/metadata/\(startingTrackRatingKey)"),
            URLQueryItem(name: "shuffle", value: shuffle ? "1" : "0"),
        ]

        let url = buildURL(base: server.baseURL, path: "playQueues", query: query)
        let container = try await requestContainer(url: url, token: token, method: "POST")
        guard let playQueueID = container.int(for: ["playQueueID"]) else {
            throw PlexAPIError.invalidResponse
        }

        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? 1, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func shufflePlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let url = buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/shuffle")
        let container = try await requestContainer(url: url, token: token, method: "PUT")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? itemCount, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func unshufflePlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let url = buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/unshuffle")
        let container = try await requestContainer(url: url, token: token, method: "PUT")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? itemCount, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func refreshPlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, centeredOn playQueueItemID: String? = nil, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: itemCount, centeredOn: playQueueItemID, userToken: userToken)
    }

    func addAlbumToPlayQueue(server: PlexServer, library: PlexMusicLibrary, album: PlexAlbum, playQueueID: Int, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        guard let libraryUUID = library.uuid else {
            throw PlexAPIError.invalidResponse
        }

        return try await addToPlayQueue(
            server: server,
            playQueueID: playQueueID,
            uri: libraryURI(uuid: libraryUUID, metadataPath: "/library/metadata/\(album.id)"),
            playlistID: nil,
            playNext: playNext,
            userToken: userToken
        )
    }

    func addPlaylistToPlayQueue(server: PlexServer, playlist: PlexPlaylist, playQueueID: Int, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await addToPlayQueue(
            server: server,
            playQueueID: playQueueID,
            uri: nil,
            playlistID: playlist.id,
            playNext: playNext,
            userToken: userToken
        )
    }

    func addStationToPlayQueue(server: PlexServer, station: PlexStation, playQueueID: Int, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        try await addToPlayQueue(
            server: server,
            playQueueID: playQueueID,
            uri: "server://\(server.id)/com.plexapp.plugins.library\(station.key)",
            playlistID: nil,
            playNext: playNext,
            userToken: userToken
        )
    }

    func removePlayQueueItem(server: PlexServer, playQueueID: Int, playQueueItemID: String, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let url = buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/items/\(playQueueItemID)")
        let container = try await requestContainer(url: url, token: token, method: "DELETE")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? itemCount - 1, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func clearPlayQueue(server: PlexServer, playQueueID: Int, userToken: String) async throws {
        let token = server.accessToken ?? userToken
        let url = buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/items")
        _ = try await request(url: url, token: token, method: "DELETE")
    }

    func movePlayQueueItem(server: PlexServer, playQueueID: Int, playQueueItemID: String, afterPlayQueueItemID: String?, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let query = afterPlayQueueItemID.map { [URLQueryItem(name: "after", value: $0)] } ?? []
        let url = buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/items/\(playQueueItemID)/move", query: query)
        let container = try await requestContainer(url: url, token: token, method: "PUT")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? itemCount, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    private func addToPlayQueue(server: PlexServer, playQueueID: Int, uri: String?, playlistID: String?, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        var query = [URLQueryItem(name: "next", value: playNext ? "1" : "0")]
        if let uri {
            query.append(URLQueryItem(name: "uri", value: uri))
        }
        if let playlistID {
            query.append(URLQueryItem(name: "playlistID", value: playlistID))
        }

        let url = buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)", query: query)
        let container = try await requestContainer(url: url, token: token, method: "PUT")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? 1, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    private func libraryURI(uuid: String, metadataPath: String) -> String {
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/")
        let encodedPath = metadataPath.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? metadataPath
        return "library://\(uuid)/item/\(encodedPath)"
    }

    func fetchLoudnessGain(server: PlexServer, ratingKey: String, userToken: String) async throws -> Float? {
        let token = server.accessToken ?? userToken
        let url = buildURL(base: server.baseURL, path: "library/metadata/\(ratingKey)")
        let data = try await request(url: url, token: token)
        let container = try mediaContainer(from: data)
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata", "Track", "track"])

        guard let trackNode = metadataNodes.first ?? container.objectArray(for: ["Track", "track"]).first,
              let selectedAudioStream = selectedAudioStream(from: trackNode),
              let gain = selectedAudioStream.float(for: ["gain"]) else {
            return nil
        }

        let peak = selectedAudioStream.float(for: ["peak", "albumPeak"])
        return clampedGain(gain, peak: peak)
    }

    func reportPlaybackTimeline(
        server: PlexServer,
        ratingKey: String,
        playQueueID: Int?,
        playQueueItemID: String?,
        state: PlaybackState,
        positionMilliseconds: Int,
        durationMilliseconds: Int,
        userToken: String
    ) async throws {
        let token = server.accessToken ?? userToken
        var query = [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(max(positionMilliseconds, 0))),
            URLQueryItem(name: "duration", value: String(max(durationMilliseconds, 0))),
            URLQueryItem(name: "type", value: "music"),
        ]

        if let playQueueID {
            query.append(URLQueryItem(name: "playQueueID", value: String(playQueueID)))
            query.append(URLQueryItem(name: "containerKey", value: "/playQueues/\(playQueueID)"))
        }

        if let playQueueItemID {
            query.append(URLQueryItem(name: "playQueueItemID", value: playQueueItemID))
        }

        let url = buildURL(base: server.baseURL, path: ":/timeline", query: query)
        _ = try await request(url: url, token: token, method: "POST")
    }

    func markTrackListened(server: PlexServer, ratingKey: String, userToken: String) async throws {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: ratingKey),
        ]
        let url = buildURL(base: server.baseURL, path: ":/scrobble", query: query)
        _ = try await request(url: url, token: token, method: "PUT")
    }

    private func parseAlbums(data: Data, server: PlexServer, token: String?) throws -> [PlexAlbum] {
        let container = try mediaContainer(from: data)
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])

        let albums = metadataNodes.compactMap { album(from: $0, server: server, token: token) }

        return deduplicate(albums)
    }

    private func album(from node: [String: Any], server: PlexServer, token: String?) -> PlexAlbum? {
        guard node.string(for: ["type"])?.lowercased() == "album",
              let id = node.string(for: ["ratingKey", "key", "id"]) else {
            return nil
        }

        let title = node.string(for: ["title"]) ?? "Unknown Album"
        let artist = node.string(for: ["parentTitle", "grandparentTitle", "originalTitle"]) ?? "Unknown Artist"
        let artworkPath = node.string(for: ["thumb", "parentThumb", "grandparentThumb", "art"])

        return PlexAlbum(
            id: id,
            title: title,
            artist: artist,
            artworkURL: artworkURL(from: artworkPath, server: server, token: token)
        )
    }

    private func parsePlaylists(data: Data) throws -> [PlexPlaylist] {
        let container = try mediaContainer(from: data)
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])

        let playlists = metadataNodes.compactMap { node -> PlexPlaylist? in
            guard let id = node.string(for: ["ratingKey", "key", "id"]),
                  let title = node.string(for: ["title"]) else {
                return nil
            }

            let playlistType = node.string(for: ["playlistType", "type"])?.lowercased()
            if let playlistType, playlistType != "audio", playlistType != "playlist" {
                return nil
            }

            let trackCount = node.int(for: ["leafCount"]) ?? 0
            return PlexPlaylist(id: id, title: title, trackCount: trackCount)
        }

        return deduplicate(playlists)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func parseStations(data: Data) throws -> [PlexStation] {
        let container = try mediaContainer(from: data)
        let stations = nestedObjects(in: container).compactMap { node -> PlexStation? in
            guard let key = node.string(for: ["key"]),
                  key.contains("/station/") || node.string(for: ["radio"]) == "1",
                  let title = node.string(for: ["title"]),
                  !["style radio", "mood radio"].contains(title.lowercased()) else {
                return nil
            }

            return PlexStation(id: key, title: title, key: key)
        }

        return deduplicate(stations)
    }

    private func nestedObjects(in value: Any) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            return [object] + object.values.flatMap(nestedObjects(in:))
        }

        if let array = value as? [Any] {
            return array.flatMap(nestedObjects(in:))
        }

        return []
    }

    private func parseTracks(data: Data, server: PlexServer, token: String?) throws -> [PlexTrack] {
        let container = try mediaContainer(from: data)
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])

        let tracks = metadataNodes.compactMap { node -> PlexTrack? in
            let type = node.string(for: ["type"])?.lowercased()
            if let type, type != "track" {
                return nil
            }

            guard let id = node.string(for: ["ratingKey", "key", "id"]) else {
                return nil
            }

            guard let streamPart = firstMediaPartPath(from: node) else {
                return nil
            }

            let streamURL = streamURL(from: streamPart, server: server, token: token)
            let artworkPath = node.string(for: ["thumb", "parentThumb", "grandparentThumb", "art"])

            return PlexTrack(
                id: id,
                playQueueItemID: nil,
                ratingKey: node.string(for: ["ratingKey", "key", "id"]),
                albumRatingKey: node.string(for: ["parentRatingKey"]),
                durationMilliseconds: node.int(for: ["duration"]),
                title: node.string(for: ["title"]) ?? "Unknown Track",
                trackArtist: node.string(for: ["originalTitle", "grandparentTitle"]),
                albumArtist: node.string(for: ["grandparentTitle", "parentTitle"]),
                albumName: node.string(for: ["parentTitle"]) ?? "Unknown Album",
                artworkURL: artworkURL(from: artworkPath, server: server, token: token),
                trackNumber: node.int(for: ["index"]),
                discNumber: node.int(for: ["parentIndex"]),
                streamURL: streamURL
            )
        }

        return deduplicate(tracks)
    }

    private func fetchPlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, centeredOn playQueueItemID: String? = nil, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        var query = [
            URLQueryItem(name: "window", value: String(max(itemCount, 1))),
            URLQueryItem(name: "includeBefore", value: "1"),
            URLQueryItem(name: "includeAfter", value: "1"),
        ]
        if let playQueueItemID {
            query.append(URLQueryItem(name: "center", value: playQueueItemID))
        }

        let url = buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)", query: query)
        let container = try await requestContainer(url: url, token: token)
        let tracks = try parsePlayQueueTracks(from: container, server: server, token: token)
        guard !tracks.isEmpty else {
            throw PlexAPIError.noTracksInLibrary
        }

        return PlexPlayQueueSnapshot(
            id: playQueueID,
            totalCount: max(container.int(for: ["playQueueTotalCount"]) ?? itemCount, tracks.count),
            selectedTrackID: container.string(for: ["playQueueSelectedItemID"]),
            version: container.int(for: ["playQueueVersion"]),
            isShuffled: container.string(for: ["playQueueShuffled"]) == "1",
            tracks: tracks
        )
    }

    private func parseTracks(from container: [String: Any], server: PlexServer, token: String?) throws -> [PlexTrack] {
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])

        let tracks = metadataNodes.compactMap { node -> PlexTrack? in
            let type = node.string(for: ["type"])?.lowercased()
            if let type, type != "track" {
                return nil
            }

            guard let id = node.string(for: ["ratingKey", "key", "id"]) else {
                return nil
            }

            guard let streamPart = firstMediaPartPath(from: node) else {
                return nil
            }

            let streamURL = streamURL(from: streamPart, server: server, token: token)
            let artworkPath = node.string(for: ["thumb", "parentThumb", "grandparentThumb", "art"])

            return PlexTrack(
                id: id,
                playQueueItemID: nil,
                ratingKey: node.string(for: ["ratingKey", "key", "id"]),
                albumRatingKey: node.string(for: ["parentRatingKey"]),
                durationMilliseconds: node.int(for: ["duration"]),
                title: node.string(for: ["title"]) ?? "Unknown Track",
                trackArtist: node.string(for: ["originalTitle", "grandparentTitle"]),
                albumArtist: node.string(for: ["grandparentTitle", "parentTitle"]),
                albumName: node.string(for: ["parentTitle"]) ?? "Unknown Album",
                artworkURL: artworkURL(from: artworkPath, server: server, token: token),
                trackNumber: node.int(for: ["index"]),
                discNumber: node.int(for: ["parentIndex"]),
                streamURL: streamURL
            )
        }

        return deduplicate(tracks)
    }

    private func parsePlayQueueTracks(from container: [String: Any], server: PlexServer, token: String?) throws -> [PlexTrack] {
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])

        return metadataNodes.compactMap { node -> PlexTrack? in
            let type = node.string(for: ["type"])?.lowercased()
            if let type, type != "track" {
                return nil
            }

            guard let id = node.string(for: ["playQueueItemID", "ratingKey", "key", "id"]) else {
                return nil
            }

            guard let streamPart = firstMediaPartPath(from: node) else {
                return nil
            }

            let streamURL = streamURL(from: streamPart, server: server, token: token)
            let artworkPath = node.string(for: ["thumb", "parentThumb", "grandparentThumb", "art"])

            return PlexTrack(
                id: id,
                playQueueItemID: node.string(for: ["playQueueItemID"]),
                ratingKey: node.string(for: ["ratingKey", "key", "id"]),
                albumRatingKey: node.string(for: ["parentRatingKey"]),
                durationMilliseconds: node.int(for: ["duration"]),
                title: node.string(for: ["title"]) ?? "Unknown Track",
                trackArtist: node.string(for: ["originalTitle", "grandparentTitle"]),
                albumArtist: node.string(for: ["grandparentTitle", "parentTitle"]),
                albumName: node.string(for: ["parentTitle"]) ?? "Unknown Album",
                artworkURL: artworkURL(from: artworkPath, server: server, token: token),
                trackNumber: node.int(for: ["index"]),
                discNumber: node.int(for: ["parentIndex"]),
                streamURL: streamURL
            )
        }
    }

    private func selectedAudioStream(from node: [String: Any]) -> [String: Any]? {
        let mediaArray = node.objectArray(for: ["Media", "media"])

        for media in mediaArray {
            for part in media.objectArray(for: ["Part", "part"]) {
                let streams = part.objectArray(for: ["Stream", "stream"])
                if let selectedStream = streams.first(where: { $0.string(for: ["streamType"]) == "2" && $0.string(for: ["selected"]) == "1" }) {
                    return selectedStream
                }

                if let firstAudioStream = streams.first(where: { $0.string(for: ["streamType"]) == "2" }) {
                    return firstAudioStream
                }
            }
        }

        return nil
    }

    private func clampedGain(_ gain: Float, peak: Float?) -> Float {
        let safeGain = min(max(gain, -20), 6)

        guard let peak, peak > 0 else {
            return safeGain
        }

        let allowedBoost = 20 * log10(1 / peak)
        return min(safeGain, allowedBoost)
    }

    private func firstMediaPartPath(from node: [String: Any]) -> String? {
        guard let mediaArray = node["Media"] as? [[String: Any]],
              let firstMedia = mediaArray.first,
              let partArray = firstMedia["Part"] as? [[String: Any]],
              let firstPart = partArray.first,
              let path = firstPart.string(for: ["key", "file"]) else {
            return nil
        }

        return path
    }

    private func streamURL(from path: String, server: PlexServer, token: String?) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path) ?? server.baseURL
        }

        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var url = server.baseURL
        for component in normalizedPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        guard let token else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        components?.queryItems = items
        return components?.url ?? url
    }

    private func deduplicate<T: Identifiable>(_ values: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        var unique: [T] = []

        for value in values where !seen.contains(value.id) {
            seen.insert(value.id)
            unique.append(value)
        }

        return unique
    }

    private func request(url: URL, token: String?, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              200 ..< 300 ~= http.statusCode else {
            throw PlexAPIError.invalidResponse
        }

        return data
    }

    private func requestContainer(url: URL, token: String?, method: String = "GET") async throws -> [String: Any] {
        let data = try await request(url: url, token: token, method: method)
        return try mediaContainer(from: data)
    }

    private func mediaContainer(from data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any] else {
            throw PlexAPIError.unsupportedResponseFormat
        }

        if let container = root["MediaContainer"] as? [String: Any] {
            return container
        }

        return root
    }

    private func resourceArray(from data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)

        if let resources = json as? [[String: Any]] {
            return resources
        }

        guard let root = json as? [String: Any] else {
            throw PlexAPIError.unsupportedResponseFormat
        }

        if let container = root["MediaContainer"] as? [String: Any] {
            return container.objectArray(for: ["Resource", "resources"])
        }

        return root.objectArray(for: ["Resource", "resources"])
    }

    private func buildURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        var url = base
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        guard !query.isEmpty else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        return components?.url ?? url
    }

    private func bestConnectionURL(from nodes: [[String: Any]]) -> URL? {
        let urls = nodes.compactMap { node -> URL? in
            guard let uri = node.string(for: ["uri", "URL"]) else { return nil }
            return URL(string: uri)
        }

        if let https = urls.first(where: { $0.scheme?.lowercased() == "https" }) {
            return https
        }

        return urls.first
    }

    private func artworkURL(from artworkPath: String?, server: PlexServer, token: String?) -> URL? {
        guard let artworkPath else {
            return nil
        }

        if artworkPath.hasPrefix("http://") || artworkPath.hasPrefix("https://") {
            return URL(string: artworkPath)
        }

        let normalizedPath = artworkPath.hasPrefix("/") ? String(artworkPath.dropFirst()) : artworkPath
        var url = server.baseURL
        for component in normalizedPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        guard let token else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        components?.queryItems = items
        return components?.url ?? url
    }

    private func applyPlexHeaders(to request: inout URLRequest) {
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("14.0", forHTTPHeaderField: "X-Plex-Platform-Version")
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(for keys: [String]) -> String? {
        for key in keys {
            if let value = self[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }

            if let value = self[key] as? NSNumber {
                return value.stringValue
            }

            if let value = self[key] as? Int {
                return String(value)
            }
        }

        return nil
    }

    func int(for keys: [String]) -> Int? {
        for key in keys {
            if let value = self[key] as? Int {
                return value
            }

            if let value = self[key] as? NSNumber {
                return value.intValue
            }

            if let value = self[key] as? String,
               let intValue = Int(value) {
                return intValue
            }
        }

        return nil
    }

    func float(for keys: [String]) -> Float? {
        for key in keys {
            if let value = self[key] as? Float {
                return value
            }

            if let value = self[key] as? Double {
                return Float(value)
            }

            if let value = self[key] as? NSNumber {
                return value.floatValue
            }

            if let value = self[key] as? String,
               let floatValue = Float(value) {
                return floatValue
            }
        }

        return nil
    }

    func objectArray(for keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let objects = self[key] as? [[String: Any]] {
                return objects
            }

            if let objects = self[key] as? [Any] {
                return objects.compactMap { $0 as? [String: Any] }
            }
        }

        return []
    }
}
