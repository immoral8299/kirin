import Foundation

enum PlexAPIError: LocalizedError {
    case invalidResponse
    case unsupportedResponseFormat
    case noReachableServer
    case noTracksInLibrary

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
        }
    }
}

struct PlexAPIClient {
    private let session: URLSession
    private let clientIdentifier = "menu-bar-plex-client"
    private let productName = "MenuBarPlexClient"

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

        async let recentlyViewedData = request(url: recentlyViewedURL, token: token)
        async let recentlyAddedData = request(url: recentlyAddedURL, token: token)
        async let playlistsData = request(url: playlistsURL, token: token)

        let recentlyPlayedAlbums = try parseAlbums(data: try await recentlyViewedData, server: server, token: token)
        let recentlyAddedAlbums = try parseAlbums(data: try await recentlyAddedData, server: server, token: token)
        let playlists = try parsePlaylists(data: try await playlistsData)

        return PlexHomeContent(
            recentlyPlayedAlbums: recentlyPlayedAlbums,
            recentlyAddedAlbums: recentlyAddedAlbums,
            playlists: playlists
        )
    }

    func fetchPlaybackQueue(server: PlexServer, library: PlexMusicLibrary, userToken: String, limit: Int = 30) async throws -> [PlexTrack] {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
            URLQueryItem(name: "type", value: "10"),
        ]

        let allURL = buildURL(base: server.baseURL, path: "library/sections/\(library.id)/all", query: query)
        let data = try await request(url: allURL, token: token)

        let tracks = try parseTracks(data: data, server: server, token: token)
        guard !tracks.isEmpty else {
            throw PlexAPIError.noTracksInLibrary
        }

        return tracks
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

    private func parseAlbums(data: Data, server: PlexServer, token: String?) throws -> [PlexAlbum] {
        let container = try mediaContainer(from: data)
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata"])

        let albums = metadataNodes.compactMap { node -> PlexAlbum? in
            let type = node.string(for: ["type"])?.lowercased()
            if let type, type != "album" {
                return nil
            }

            guard let id = node.string(for: ["ratingKey", "key", "id"]) else {
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

        return deduplicate(albums)
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
                ratingKey: node.string(for: ["ratingKey", "key", "id"]),
                title: node.string(for: ["title"]) ?? "Unknown Track",
                trackArtist: node.string(for: ["originalTitle", "grandparentTitle"]),
                albumArtist: node.string(for: ["grandparentTitle", "parentTitle"]),
                albumName: node.string(for: ["parentTitle"]) ?? "Unknown Album",
                artworkURL: artworkURL(from: artworkPath, server: server, token: token),
                streamURL: streamURL
            )
        }

        return deduplicate(tracks)
    }

    private func fetchPlayQueue(server: PlexServer, playQueueID: Int, itemCount: Int, userToken: String) async throws -> PlexPlayQueueSnapshot {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "window", value: String(max(itemCount, 1))),
            URLQueryItem(name: "includeBefore", value: "1"),
            URLQueryItem(name: "includeAfter", value: "1"),
        ]

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
                ratingKey: node.string(for: ["ratingKey", "key", "id"]),
                title: node.string(for: ["title"]) ?? "Unknown Track",
                trackArtist: node.string(for: ["originalTitle", "grandparentTitle"]),
                albumArtist: node.string(for: ["grandparentTitle", "parentTitle"]),
                albumName: node.string(for: ["parentTitle"]) ?? "Unknown Album",
                artworkURL: artworkURL(from: artworkPath, server: server, token: token),
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
                ratingKey: node.string(for: ["ratingKey", "key", "id"]),
                title: node.string(for: ["title"]) ?? "Unknown Track",
                trackArtist: node.string(for: ["originalTitle", "grandparentTitle"]),
                albumArtist: node.string(for: ["grandparentTitle", "parentTitle"]),
                albumName: node.string(for: ["parentTitle"]) ?? "Unknown Album",
                artworkURL: artworkURL(from: artworkPath, server: server, token: token),
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
