import Foundation

struct PlexPlayQueueService {
    private let client: PlexNetworkClient
    private let content: PlexContentService

    init(client: PlexNetworkClient, content: PlexContentService) {
        self.client = client
        self.content = content
    }

    func createPlaylistPlayQueue(server: PlexServer, playlist: PlexPlaylist, userToken: String, shuffle: Bool) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "playlistID", value: playlist.id),
            URLQueryItem(name: "type", value: "audio"),
            URLQueryItem(name: "shuffle", value: shuffle ? "1" : "0"),
        ]

        let url = client.buildURL(base: server.baseURL, path: "playQueues", query: query)
        let container = try await client.requestContainer(url: url, token: token, method: "POST")
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

        let url = client.buildURL(base: server.baseURL, path: "playQueues", query: query)
        let container = try await client.requestContainer(url: url, token: token, method: "POST")
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

        let url = client.buildURL(base: server.baseURL, path: "playQueues", query: query)
        let container = try await client.requestContainer(url: url, token: token, method: "POST")
        guard let playQueueID = container.int(for: ["playQueueID"]) else {
            throw PlexAPIError.invalidResponse
        }

        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? 1, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func shufflePlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/shuffle")
        let container = try await client.requestContainer(url: url, token: token, method: "PUT")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? itemCount, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func unshufflePlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/unshuffle")
        let container = try await client.requestContainer(url: url, token: token, method: "PUT")
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
        let url = client.buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/items/\(playQueueItemID)")
        let container = try await client.requestContainer(url: url, token: token, method: "DELETE")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? itemCount - 1, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    func clearPlayQueue(server: PlexServer, playQueueID: Int, userToken: String) async throws {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/items")
        _ = try await client.request(url: url, token: token, method: "DELETE")
    }

    func movePlayQueueItem(server: PlexServer, playQueueID: Int, playQueueItemID: String, afterPlayQueueItemID: String?, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let query = afterPlayQueueItemID.map { [URLQueryItem(name: "after", value: $0)] } ?? []
        let url = client.buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)/items/\(playQueueItemID)/move", query: query)
        let container = try await client.requestContainer(url: url, token: token, method: "PUT")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? itemCount, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    // MARK: - Private helpers

    private func addToPlayQueue(server: PlexServer, playQueueID: Int, uri: String?, playlistID: String?, playNext: Bool, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        var query = [URLQueryItem(name: "next", value: playNext ? "1" : "0")]
        if let uri {
            query.append(URLQueryItem(name: "uri", value: uri))
        }
        if let playlistID {
            query.append(URLQueryItem(name: "playlistID", value: playlistID))
        }

        let url = client.buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)", query: query)
        let container = try await client.requestContainer(url: url, token: token, method: "PUT")
        let totalCount = max(container.int(for: ["playQueueTotalCount"]) ?? 1, 1)
        return try await fetchPlayQueue(server: server, playQueueID: playQueueID, itemCount: totalCount, userToken: userToken)
    }

    private func libraryURI(uuid: String, metadataPath: String) -> String {
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/")
        let encodedPath = metadataPath.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? metadataPath
        return "library://\(uuid)/item/\(encodedPath)"
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

        let url = client.buildURL(base: server.baseURL, path: "playQueues/\(playQueueID)", query: query)
        let container = try await client.requestContainer(url: url, token: token)
        let tracks = content.parsePlayQueueTracks(from: container, server: server, token: token)
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
}
