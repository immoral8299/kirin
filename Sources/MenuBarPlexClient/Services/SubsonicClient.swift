import Foundation

enum NavidromeError: LocalizedError {
    case invalidResponse
    case notFound
    case authenticationFailed
    case notSupported(String)
    case apiError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .notFound: return "Resource not found"
        case .authenticationFailed: return "Authentication failed. Check your username and password."
        case .notSupported(let message): return message
        case .apiError(_, let message): return message
        }
    }
}

struct SubsonicClient {
    let baseURL: URL
    let username: String
    let password: String
    let session: URLSession

    private let apiVersion = "1.16.1"
    private let clientName = "Kirin"

    private var authSalt: String { String(UUID().uuidString.prefix(8)) }

    private func authToken(salt: String) -> String { SubsonicCrypto.md5(password + salt) }

    private func buildURL(path: String, extraParams: [(String, String)] = []) -> URL {
        let salt = authSalt
        let token = authToken(salt: salt)
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        for (key, value) in extraParams {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems
        return components.url!
    }

    private func checkForError(data: Data) throws {
        struct ErrorWrapper: Decodable {
            struct ErrorInfo: Decodable {
                let code: Int
                let message: String
            }
            let status: String
            let error: ErrorInfo?
        }
        guard let wrapper = try? JSONDecoder().decode(SubsonicResponse<ErrorWrapper>.self, from: data) else { return }
        if wrapper.subsonicResponse.status == "failed", let error = wrapper.subsonicResponse.error {
            throw NavidromeError.apiError(code: error.code, message: error.message)
        }
    }

    private func request<T: Decodable>(path: String, extraParams: [(String, String)] = []) async throws -> T {
        let url = buildURL(path: path, extraParams: extraParams)
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NavidromeError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw NavidromeError.authenticationFailed
        }
        guard httpResponse.statusCode == 200 else {
            throw NavidromeError.invalidResponse
        }
        try checkForError(data: data)
        let decoder = JSONDecoder()
        let wrapper = try decoder.decode(SubsonicResponse<T>.self, from: data)
        return wrapper.subsonicResponse
    }

    func ping() async throws -> SubsonicPingResponse {
        try await request(path: "/rest/ping")
    }

    func getAlbumList(type: String, offset: Int = 0, size: Int = 12) async throws -> [SubsonicAlbum] {
        let container: SubsonicAlbumList2Container = try await request(path: "/rest/getAlbumList2", extraParams: [
            ("type", type),
            ("offset", String(offset)),
            ("size", String(size)),
        ])
        return container.albumList2.album ?? []
    }

    func getAlbum(id: String) async throws -> SubsonicAlbumDetail {
        let container: SubsonicAlbumContainer = try await request(path: "/rest/getAlbum", extraParams: [
            ("id", id),
        ])
        return container.album
    }

    func getArtist(id: String) async throws -> SubsonicArtistDetail {
        let container: SubsonicArtistContainer = try await request(path: "/rest/getArtist", extraParams: [
            ("id", id),
        ])
        return container.artist
    }

    func getPlaylists() async throws -> [SubsonicPlaylist] {
        let container: SubsonicPlaylistsContainer = try await request(path: "/rest/getPlaylists")
        return container.playlists.playlist ?? []
    }

    func getPlaylist(id: String) async throws -> [SubsonicTrack] {
        struct PlaylistWithSongs: Decodable {
            let entry: [SubsonicTrack]?
        }
        struct PlaylistContainer: Decodable {
            let playlist: PlaylistWithSongs
        }
        let container: PlaylistContainer = try await request(path: "/rest/getPlaylist", extraParams: [
            ("id", id),
        ])
        return container.playlist.entry ?? []
    }

    func getSong(id: String) async throws -> SubsonicTrack {
        struct SongContainer: Decodable {
            let song: SubsonicTrack
        }
        let container: SongContainer = try await request(path: "/rest/getSong", extraParams: [
            ("id", id),
        ])
        return container.song
    }

    func getGenres() async throws -> [SubsonicGenre] {
        let container: SubsonicGenresContainer = try await request(path: "/rest/getGenres")
        return container.genres.genre ?? []
    }

    func getSongsByGenre(genre: String, count: Int = 50, offset: Int = 0) async throws -> [SubsonicTrack] {
        let container: SubsonicSongsByGenreContainer = try await request(path: "/rest/getSongsByGenre", extraParams: [
            ("genre", genre),
            ("count", String(count)),
            ("offset", String(offset)),
        ])
        return container.songsByGenre.song ?? []
    }

    func search(query: String, limit: Int = 20) async throws -> SubsonicSearchResult {
        let container: SubsonicSearchResultContainer = try await request(path: "/rest/search3", extraParams: [
            ("query", query),
            ("artistCount", String(limit)),
            ("artistOffset", "0"),
            ("albumCount", String(limit)),
            ("albumOffset", "0"),
            ("songCount", String(limit)),
            ("songOffset", "0"),
        ])
        return container.searchResult
    }

    func streamURL(id: String) -> URL {
        buildURL(path: "/rest/stream", extraParams: [("id", id)])
    }

    func coverArtURL(id: String) -> URL {
        buildURL(path: "/rest/getCoverArt", extraParams: [("id", id)])
    }

    func scrobble(id: String, submission: Bool = true, time: Date? = nil) async throws {
        var params: [(String, String)] = [("id", id), ("submission", submission ? "true" : "false")]
        if let time {
            params.append(("time", String(Int(time.timeIntervalSince1970))))
        }
        struct EmptyResponse: Decodable {}
        let _: EmptyResponse = try await request(path: "/rest/scrobble", extraParams: params)
    }
}
