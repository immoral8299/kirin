import Foundation
import CryptoKit

// MARK: - Generic Subsonic Response Wrapper

struct SubsonicResponse<T: Decodable>: Decodable {
    let subsonicResponse: T

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

// MARK: - MD5 Helper (Subsonic token auth)

enum SubsonicCrypto {
    static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Ping Response

struct SubsonicPingResponse: Decodable {
    let status: String
    let version: String
}

// MARK: - Album List

struct SubsonicAlbumList2: Decodable {
    let album: [SubsonicAlbum]?
}

struct SubsonicAlbum: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let created: String?
    let isDir: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, artist, coverArt, songCount, duration, year, genre, created, isDir
        case artistId = "artistId"
    }
}

// MARK: - Album Detail (tracks)

struct SubsonicAlbumDetail: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let song: [SubsonicTrack]?
    let duration: Int?
    let year: Int?
    let genre: String?

    enum CodingKeys: String, CodingKey {
        case id, name, artist, coverArt, song, duration, year, genre
        case artistId = "artistId"
    }
}

// MARK: - Artist Detail

struct SubsonicArtist: Decodable {
    let id: String
    let name: String
    let coverArt: String?
    let albumCount: Int?
}

struct SubsonicArtistDetail: Decodable {
    let id: String
    let name: String
    let coverArt: String?
    let album: [SubsonicAlbum]?
    let albumCount: Int?
}

// MARK: - Track (Song)

struct SubsonicTrack: Decodable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let albumId: String?
    let coverArt: String?
    let duration: Int?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let size: Int?
    let contentType: String?
    let suffix: String?
    let bitRate: Int?
    let path: String?
    let replayGain: SubsonicReplayGain?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, coverArt, duration, track, year, genre
        case size, contentType, suffix, bitRate, path, replayGain
        case albumId = "albumId"
        case discNumber = "discNumber"
    }
}

struct SubsonicReplayGain: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?

    enum CodingKeys: String, CodingKey {
        case trackGain = "trackGain"
        case albumGain = "albumGain"
        case trackPeak = "trackPeak"
        case albumPeak = "albumPeak"
    }
}

// MARK: - Genres

struct SubsonicGenre: Decodable {
    let name: String
    let songCount: Int?
    let albumCount: Int?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            name = value
            songCount = nil
            albumCount = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        songCount = try container.decodeIfPresent(Int.self, forKey: .songCount)
        albumCount = try container.decodeIfPresent(Int.self, forKey: .albumCount)
        name = try container.decodeIfPresent(String.self, forKey: .value)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case value
        case songCount
        case albumCount
    }
}

struct SubsonicGenres: Decodable {
    let genre: [SubsonicGenre]?
}

struct SubsonicSongsByGenre: Decodable {
    let song: [SubsonicTrack]?
}

// MARK: - Search

struct SubsonicSearchResult: Decodable {
    let artist: [SubsonicArtist]?
    let album: [SubsonicAlbum]?
    let song: [SubsonicTrack]?
}

// MARK: - Playlist

struct SubsonicPlaylists: Decodable {
    let playlist: [SubsonicPlaylist]?
}

struct SubsonicPlaylist: Decodable {
    let id: String
    let name: String
    let songCount: Int?
    let duration: Int?
    let owner: String?
    let isPublic: Bool?
    let coverArt: String?
    let created: String?
    let changed: String?

    enum CodingKeys: String, CodingKey {
        case id, name, songCount, duration, owner, coverArt, created, changed
        case isPublic = "public"
    }
}

// MARK: - Response Containers

struct SubsonicAlbumList2Container: Decodable {
    let albumList2: SubsonicAlbumList2
}

struct SubsonicAlbumContainer: Decodable {
    let album: SubsonicAlbumDetail
}

struct SubsonicArtistContainer: Decodable {
    let artist: SubsonicArtistDetail
}

struct SubsonicPlaylistsContainer: Decodable {
    let playlists: SubsonicPlaylists
}

struct SubsonicGenresContainer: Decodable {
    let genres: SubsonicGenres
}

struct SubsonicSongsByGenreContainer: Decodable {
    let songsByGenre: SubsonicSongsByGenre
}

struct SubsonicSearchResultContainer: Decodable {
    let searchResult: SubsonicSearchResult

    enum CodingKeys: String, CodingKey {
        case searchResult = "searchResult3"
    }
}
