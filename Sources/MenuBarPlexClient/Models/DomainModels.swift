import Foundation

enum PlaybackState: String, Codable {
    case playing
    case paused
    case buffering
    case stopped

}

struct TrackMetadata: Codable, Equatable {
    var trackName: String
    var trackArtist: String?
    var albumArtist: String?
    var albumName: String
    var artworkURL: URL?
    var trackNumber: Int?
    var discNumber: Int?

    var resolvedTrackArtist: String {
        let trimmedTrackArtist = trackArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTrackArtist, !trimmedTrackArtist.isEmpty {
            return trimmedTrackArtist
        }

        let trimmedAlbumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAlbumArtist, !trimmedAlbumArtist.isEmpty {
            return trimmedAlbumArtist
        }

        return "Unknown Artist"
    }

    static let placeholder = TrackMetadata(
        trackName: "Unknown Track",
        trackArtist: nil,
        albumArtist: nil,
        albumName: "Unknown Album",
        artworkURL: nil,
        trackNumber: nil,
        discNumber: nil
    )
}

struct PlexAlbum: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
}

struct PlexPlaylist: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let trackCount: Int
}

struct PlexStation: Identifiable, Hashable {
    let id: String
    let title: String
    let key: String
}

enum MediaStationRecommendationKind: Hashable {
    case artist
    case album
}

struct MediaStationRecommendation: Identifiable, Hashable {
    let kind: MediaStationRecommendationKind
    let seedID: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let station: MediaStation?

    var id: String {
        "\(kind)-\(seedID)"
    }
}

enum PendingPlaybackID {
    static func album(_ id: String) -> String { "album-\(id)" }
    static func playlist(_ id: String) -> String { "playlist-\(id)" }
    static func station(_ id: String) -> String { "station-\(id)" }
    static func track(_ id: String) -> String { "track-\(id)" }
    static func recommendation(_ id: String) -> String { "recommendation-\(id)" }
}

struct PlexTrack: Identifiable, Hashable {
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

struct PlexPlayQueueSnapshot {
    let id: Int
    let totalCount: Int
    let selectedTrackID: String?
    let version: Int?
    let isShuffled: Bool
    let tracks: [PlexTrack]
}

struct PlexServer: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let accessToken: String?
    let baseURL: URL
}

struct PlexMusicLibrary: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let uuid: String?
}

struct PlexHomeContent {
    let recentlyPlayedAlbums: [PlexAlbum]
    let recentlyAddedAlbums: [PlexAlbum]
    let playlists: [PlexPlaylist]
    let stations: [PlexStation]
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
