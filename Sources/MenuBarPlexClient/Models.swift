import Foundation

enum PlaybackState: String, Codable {
    case playing
    case paused
    case buffering
    case stopped

    var systemImageName: String {
        switch self {
        case .playing:
            return "pause.fill"
        case .paused, .stopped:
            return "play.fill"
        case .buffering:
            return "hourglass"
        }
    }
}

struct TrackMetadata: Codable, Equatable {
    var trackName: String
    var trackArtist: String?
    var albumArtist: String?
    var albumName: String
    var artworkURL: URL?

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
        trackName: "Not Playing",
        trackArtist: nil,
        albumArtist: nil,
        albumName: "",
        artworkURL: nil
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

struct PlexTrack: Identifiable, Hashable {
    let id: String
    let ratingKey: String?
    let title: String
    let trackArtist: String?
    let albumArtist: String?
    let albumName: String
    let artworkURL: URL?
    let streamURL: URL
}

struct PlexPlayQueueSnapshot {
    let id: Int
    let totalCount: Int
    let selectedTrackID: String?
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
}

enum MenuBarField: String, CaseIterable, Codable, Identifiable {
    case albumArtist
    case trackArtistWithFallback
    case trackName
    case albumName

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .albumArtist:
            return "Album Artist"
        case .trackArtistWithFallback:
            return "Track Artist (Fallback)"
        case .trackName:
            return "Track Name"
        case .albumName:
            return "Album Name"
        }
    }

    func value(from metadata: TrackMetadata) -> String {
        switch self {
        case .albumArtist:
            return metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Unknown Artist"
        case .trackArtistWithFallback:
            return metadata.resolvedTrackArtist
        case .trackName:
            return metadata.trackName
        case .albumName:
            return metadata.albumName.nonEmpty ?? "Unknown Album"
        }
    }
}

struct MenuBarFormat: Codable, Equatable {
    var firstField: MenuBarField
    var secondField: MenuBarField

    static let `default` = MenuBarFormat(
        firstField: .trackArtistWithFallback,
        secondField: .trackName
    )

    func render(with metadata: TrackMetadata) -> String {
        "\(firstField.value(from: metadata)) - \(secondField.value(from: metadata))"
    }
}

struct SectionVisibility: Codable, Equatable {
    var showRecentlyPlayedAlbums: Bool
    var showRecentlyAddedAlbums: Bool
    var showPlaylists: Bool

    static let `default` = SectionVisibility(
        showRecentlyPlayedAlbums: true,
        showRecentlyAddedAlbums: true,
        showPlaylists: true
    )
}

struct AppSettings: Codable, Equatable {
    var menuBarFormat: MenuBarFormat
    var sectionVisibility: SectionVisibility
    var selectedServerID: String?
    var selectedLibraryID: String?
    var loudnessLevelingEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case menuBarFormat
        case sectionVisibility
        case selectedServerID
        case selectedLibraryID
        case loudnessLevelingEnabled
    }

    init(
        menuBarFormat: MenuBarFormat,
        sectionVisibility: SectionVisibility,
        selectedServerID: String?,
        selectedLibraryID: String?,
        loudnessLevelingEnabled: Bool
    ) {
        self.menuBarFormat = menuBarFormat
        self.sectionVisibility = sectionVisibility
        self.selectedServerID = selectedServerID
        self.selectedLibraryID = selectedLibraryID
        self.loudnessLevelingEnabled = loudnessLevelingEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBarFormat = try container.decode(MenuBarFormat.self, forKey: .menuBarFormat)
        sectionVisibility = try container.decode(SectionVisibility.self, forKey: .sectionVisibility)
        selectedServerID = try container.decodeIfPresent(String.self, forKey: .selectedServerID)
        selectedLibraryID = try container.decodeIfPresent(String.self, forKey: .selectedLibraryID)
        loudnessLevelingEnabled = try container.decodeIfPresent(Bool.self, forKey: .loudnessLevelingEnabled) ?? false
    }

    static let `default` = AppSettings(
        menuBarFormat: .default,
        sectionVisibility: .default,
        selectedServerID: nil,
        selectedLibraryID: nil,
        loudnessLevelingEnabled: false
    )
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
