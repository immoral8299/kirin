import Foundation

struct PlexContentService {
    private let client: PlexNetworkClient

    init(client: PlexNetworkClient) {
        self.client = client
    }

    func fetchHomeContent(server: PlexServer, library: PlexMusicLibrary, userToken: String, limit: Int = 12) async throws -> PlexHomeContent {
        let token = server.accessToken ?? userToken
        let pageQuery = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
        ]

        let recentlyViewedURL = client.buildURL(
            base: server.baseURL,
            path: "library/sections/\(library.id)/recentlyViewed",
            query: [URLQueryItem(name: "type", value: "9")] + pageQuery
        )

        let recentlyAddedURL = client.buildURL(
            base: server.baseURL,
            path: "library/sections/\(library.id)/recentlyAdded",
            query: [URLQueryItem(name: "type", value: "9")] + pageQuery
        )

        let playlistsURL = client.buildURL(
            base: server.baseURL,
            path: "playlists",
            query: [
                URLQueryItem(name: "playlistType", value: "audio"),
                URLQueryItem(name: "includeCollections", value: "0"),
            ] + pageQuery
        )

        let stationsURL = client.buildURL(
            base: server.baseURL,
            path: "hubs/sections/\(library.id)",
            query: [
                URLQueryItem(name: "includeStations", value: "1"),
                URLQueryItem(name: "includeStationDirectories", value: "1"),
            ]
        )

        async let recentlyViewedData = client.request(url: recentlyViewedURL, token: token)
        async let recentlyAddedData = client.request(url: recentlyAddedURL, token: token)
        async let playlistsData = client.request(url: playlistsURL, token: token)
        async let stationsData = client.request(url: stationsURL, token: token)

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

        let albumQuery = [
            URLQueryItem(name: "type", value: "9"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "1"),
        ]
        let albumURL = client.buildURL(base: server.baseURL, path: "library/sections/\(library.id)/recentlyViewed", query: albumQuery)
        let albumData = try await client.request(url: albumURL, token: token)
        let albums = try parseAlbums(data: albumData, server: server, token: token)
        guard let lastAlbum = albums.first else {
            return nil
        }

        let tracksURL = client.buildURL(base: server.baseURL, path: "library/metadata/\(lastAlbum.id)/children")
        let tracksData = try await client.request(url: tracksURL, token: token)
        return try parseTracks(data: tracksData, server: server, token: token).first
    }

    func searchLibrary(server: PlexServer, library: PlexMusicLibrary, userToken: String, query: String, limit: Int) async throws -> MediaSearchResults {
        let token = server.accessToken ?? userToken
        let pageQuery = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
        ]

        let tracksURL = client.buildURL(
            base: server.baseURL,
            path: "library/sections/\(library.id)/search",
            query: [URLQueryItem(name: "type", value: "10")] + pageQuery
        )
        let albumsURL = client.buildURL(
            base: server.baseURL,
            path: "library/sections/\(library.id)/search",
            query: [URLQueryItem(name: "type", value: "9")] + pageQuery
        )
        let artistsURL = client.buildURL(
            base: server.baseURL,
            path: "library/sections/\(library.id)/search",
            query: [URLQueryItem(name: "type", value: "8")] + pageQuery
        )

        async let tracksData = client.request(url: tracksURL, token: token)
        async let albumsData = client.request(url: albumsURL, token: token)
        async let artistsData = client.request(url: artistsURL, token: token)

        var tracks = try parseTracks(data: try await tracksData, server: server, token: token)
        var albums = try parseAlbums(data: try await albumsData, server: server, token: token)
        let artists = try parseArtists(data: try await artistsData)

        for artist in artists {
            let artistAlbums = (try? await fetchArtistAlbums(server: server, artistID: artist.id, userToken: userToken)) ?? []
            albums.append(contentsOf: artistAlbums)

            for album in artistAlbums where tracks.count < limit {
                guard let albumTracks = try? await fetchAlbumTracks(server: server, album: album, userToken: userToken) else {
                    continue
                }
                tracks.append(contentsOf: albumTracks)
            }
        }

        return MediaSearchResults(
            tracks: deduplicate(tracks).prefix(limit).map(\.mediaTrack),
            albums: deduplicate(albums).prefix(limit).map(\.mediaAlbum)
        )
    }

    func fetchAlbumTracks(server: PlexServer, album: PlexAlbum, userToken: String) async throws -> [PlexTrack] {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "library/metadata/\(album.id)/children")
        let data = try await client.request(url: url, token: token)

        let tracks = try parseTracks(data: data, server: server, token: token)
        guard !tracks.isEmpty else {
            throw PlexAPIError.noTracksInLibrary
        }

        return tracks
    }

    func fetchRelatedAlbums(server: PlexServer, albumRatingKey: String, userToken: String, limit: Int = 3) async throws -> [PlexAlbum] {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "hubs/metadata/\(albumRatingKey)/related")
        let data = try await client.request(url: url, token: token)
        let container = try client.mediaContainer(from: data)

        return deduplicate(nestedObjects(in: container).compactMap { node -> PlexAlbum? in
            guard node.string(for: ["ratingKey"]) != nil else { return nil }
            return album(from: node, server: server, token: token)
        })
            .filter { $0.id != albumRatingKey }
            .prefix(limit)
            .map { $0 }
    }

    func fetchArtistAlbums(server: PlexServer, artistID: String, userToken: String) async throws -> [PlexAlbum] {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "library/metadata/\(artistID)/children")
        let data = try await client.request(url: url, token: token)
        return try parseAlbums(data: data, server: server, token: token)
    }

    func fetchPlaylistTracks(server: PlexServer, playlist: PlexPlaylist, userToken: String) async throws -> [PlexTrack] {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "playlistType", value: "audio"),
            URLQueryItem(name: "includeCollections", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "200"),
        ]

        let url = client.buildURL(base: server.baseURL, path: "playlists/\(playlist.id)/items", query: query)
        let data = try await client.request(url: url, token: token)

        let tracks = try parseTracks(data: data, server: server, token: token)
        guard !tracks.isEmpty else {
            throw PlexAPIError.noTracksInLibrary
        }

        return tracks
    }

    func fetchArtistStation(server: PlexServer, artistRatingKey: String, userToken: String) async throws -> PlexStation? {
        try await fetchMetadataStation(server: server, ratingKey: artistRatingKey, userToken: userToken)
    }

    func fetchAlbumRadioTracks(server: PlexServer, albumRatingKey: String, userToken: String, similarAlbumLimit: Int = 4) async throws -> [PlexTrack] {
        let seedAlbum = PlexAlbum(id: albumRatingKey, title: "", artist: "", artworkURL: nil)
        let similarAlbums = try await fetchRelatedAlbums(
            server: server,
            albumRatingKey: albumRatingKey,
            userToken: userToken,
            limit: similarAlbumLimit
        )

        var tracks = try await fetchAlbumTracks(server: server, album: seedAlbum, userToken: userToken)
        for album in similarAlbums {
            tracks.append(contentsOf: try await fetchAlbumTracks(server: server, album: album, userToken: userToken))
        }

        return deduplicate(tracks)
    }

    // MARK: - Parsing helpers

    private enum TrackParsingMode {
        case plain
        case playQueue
    }

    private func parseTrack(from node: [String: Any], server: PlexServer, token: String?, mode: TrackParsingMode) -> PlexTrack? {
        let type = node.string(for: ["type"])?.lowercased()
        if let type, type != "track" {
            return nil
        }

        let idKeys: [String] = {
            switch mode {
            case .playQueue: return ["playQueueItemID", "ratingKey", "key", "id"]
            case .plain: return ["ratingKey", "key", "id"]
            }
        }()

        guard let id = node.string(for: idKeys) else {
            return nil
        }

        guard let streamPart = firstMediaPartPath(from: node) else {
            return nil
        }

        let streamURL = plexStreamURL(from: streamPart, server: server, token: token)
        let artworkPath = node.string(for: ["thumb", "parentThumb", "grandparentThumb", "art"])

        return PlexTrack(
            id: id,
            playQueueItemID: mode == .playQueue ? node.string(for: ["playQueueItemID"]) : nil,
            ratingKey: node.string(for: ["ratingKey", "key", "id"]),
            albumRatingKey: node.string(for: ["parentRatingKey"]),
            artistRatingKey: node.string(for: ["grandparentRatingKey"]),
            durationMilliseconds: node.int(for: ["duration"]),
            title: node.string(for: ["title"]) ?? "Unknown Track",
            trackArtist: node.string(for: ["originalTitle", "grandparentTitle"]),
            albumArtist: node.string(for: ["grandparentTitle", "parentTitle"]),
            albumName: node.string(for: ["parentTitle"]) ?? "Unknown Album",
            artworkURL: plexArtworkURL(from: artworkPath, server: server, token: token),
            trackNumber: node.int(for: ["index"]),
            discNumber: node.int(for: ["parentIndex"]),
            streamURL: streamURL
        )
    }

    func parsePlayQueueTracks(from container: [String: Any], server: PlexServer, token: String?) -> [PlexTrack] {
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])
        return metadataNodes.compactMap { parseTrack(from: $0, server: server, token: token, mode: .playQueue) }
    }

    func parseTracks(data: Data, server: PlexServer, token: String?) throws -> [PlexTrack] {
        let container = try client.decodeContainer(PlexTrackItem.self, from: data)
        if let items = container.metadata {
            return deduplicate(items.compactMap { track(from: $0, server: server, token: token) })
        }
        let dictContainer = try client.mediaContainer(from: data)
        let metadataNodes = dictContainer.objectArray(for: ["Metadata", "metadata"])
        let tracks = metadataNodes.compactMap { parseTrack(from: $0, server: server, token: token, mode: .plain) }
        return deduplicate(tracks)
    }

    private func track(from item: PlexTrackItem, server: PlexServer, token: String?) -> PlexTrack? {
        guard item.type == nil || item.type?.lowercased() == "track" else { return nil }

        let streamPart = item.media?.first?.part?.first?.key ?? item.media?.first?.part?.first?.file
        guard let streamPart else { return nil }

        let streamURL = plexStreamURL(from: streamPart, server: server, token: token)
        let artworkPath = item.thumb ?? item.parentThumb ?? item.grandparentThumb ?? item.art

        return PlexTrack(
            id: item.ratingKey,
            playQueueItemID: nil,
            ratingKey: item.ratingKey,
            albumRatingKey: item.parentRatingKey,
            artistRatingKey: item.grandparentRatingKey,
            durationMilliseconds: item.duration,
            title: item.title ?? "Unknown Track",
            trackArtist: item.originalTitle ?? item.grandparentTitle,
            albumArtist: item.grandparentTitle ?? item.parentTitle,
            albumName: item.parentTitle ?? "Unknown Album",
            artworkURL: plexArtworkURL(from: artworkPath, server: server, token: token),
            trackNumber: item.index,
            discNumber: item.parentIndex,
            streamURL: streamURL
        )
    }

    func parseAlbums(data: Data, server: PlexServer, token: String?) throws -> [PlexAlbum] {
        let container = try client.mediaContainer(from: data)
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
            artworkURL: plexArtworkURL(from: artworkPath, server: server, token: token)
        )
    }

    private struct PlexArtistSearchResult: Identifiable {
        let id: String
    }

    private func parseArtists(data: Data) throws -> [PlexArtistSearchResult] {
        let container = try client.mediaContainer(from: data)
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])
        let artists = metadataNodes.compactMap { node -> PlexArtistSearchResult? in
            guard node.string(for: ["type"])?.lowercased() == "artist",
                  let id = node.string(for: ["ratingKey", "key", "id"]) else {
                return nil
            }
            return PlexArtistSearchResult(id: id)
        }
        return deduplicate(artists)
    }

    private func parsePlaylists(data: Data) throws -> [PlexPlaylist] {
        let container = try client.mediaContainer(from: data)
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
        let container = try client.mediaContainer(from: data)
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

    private func fetchMetadataStation(server: PlexServer, ratingKey: String, userToken: String) async throws -> PlexStation? {
        let token = server.accessToken ?? userToken
        let query = [URLQueryItem(name: "includeStations", value: "1")]
        let url = client.buildURL(base: server.baseURL, path: "library/metadata/\(ratingKey)", query: query)
        let data = try await client.request(url: url, token: token)
        let container = try client.mediaContainer(from: data)

        return nestedObjects(in: container).compactMap { node -> PlexStation? in
            guard let key = node.string(for: ["key"]),
                  key.contains("/station/"),
                  let title = node.string(for: ["title"]) else {
                return nil
            }

            return PlexStation(id: key, title: title, key: key)
        }.first
    }
}
