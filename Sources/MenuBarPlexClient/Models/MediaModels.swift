import Foundation

struct MediaServer: Identifiable, Hashable {
    let id: String
    let name: String
    let accessToken: String?
    let baseURL: URL
}

struct MediaMusicLibrary: Identifiable, Hashable {
    let id: String
    let title: String
    let uuid: String?
}

struct MediaAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
}

struct MediaPlaylist: Identifiable, Hashable {
    let id: String
    let title: String
    let trackCount: Int
}

struct MediaStation: Identifiable, Hashable {
    let id: String
    let title: String
    let key: String
}

struct MediaTrack: Identifiable, Hashable {
    let id: String
    let playQueueItemID: String?
    let ratingKey: String?
    let albumRatingKey: String?
    let artistRatingKey: String?
    let durationMilliseconds: Int?
    let title: String
    let trackArtist: String?
    let albumArtist: String?
    let albumName: String
    let artworkURL: URL?
    let trackNumber: Int?
    let discNumber: Int?
    let streamURL: URL
}

struct MediaHomeContent {
    let recentlyPlayedAlbums: [MediaAlbum]
    let recentlyAddedAlbums: [MediaAlbum]
    let playlists: [MediaPlaylist]
    let stations: [MediaStation]
}

struct MediaSearchResults {
    let tracks: [MediaTrack]
    let albums: [MediaAlbum]
}

struct PlayQueueSnapshot {
    let id: Int
    let totalCount: Int
    let selectedTrackID: String?
    let version: Int?
    let isShuffled: Bool
    let tracks: [MediaTrack]
}
