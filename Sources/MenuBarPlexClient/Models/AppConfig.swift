import Foundation

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
    var showStations: Bool

    private enum CodingKeys: String, CodingKey {
        case showRecentlyPlayedAlbums
        case showRecentlyAddedAlbums
        case showPlaylists
        case showStations
    }

    init(
        showRecentlyPlayedAlbums: Bool,
        showRecentlyAddedAlbums: Bool,
        showPlaylists: Bool,
        showStations: Bool
    ) {
        self.showRecentlyPlayedAlbums = showRecentlyPlayedAlbums
        self.showRecentlyAddedAlbums = showRecentlyAddedAlbums
        self.showPlaylists = showPlaylists
        self.showStations = showStations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showRecentlyPlayedAlbums = try container.decode(Bool.self, forKey: .showRecentlyPlayedAlbums)
        showRecentlyAddedAlbums = try container.decode(Bool.self, forKey: .showRecentlyAddedAlbums)
        showPlaylists = try container.decode(Bool.self, forKey: .showPlaylists)
        showStations = try container.decodeIfPresent(Bool.self, forKey: .showStations) ?? true
    }

    static let `default` = SectionVisibility(
        showRecentlyPlayedAlbums: true,
        showRecentlyAddedAlbums: true,
        showPlaylists: true,
        showStations: true
    )
}

enum AppThemePreference: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var menuBarFormat: MenuBarFormat
    var sectionVisibility: SectionVisibility
    var selectedServerID: String?
    var selectedLibraryID: String?
    var loudnessLevelingEnabled: Bool
    var listenedThresholdPercentage: Int
    var themePreference: AppThemePreference

    private enum CodingKeys: String, CodingKey {
        case menuBarFormat
        case sectionVisibility
        case selectedServerID
        case selectedLibraryID
        case loudnessLevelingEnabled
        case listenedThresholdPercentage
        case themePreference
    }

    init(
        menuBarFormat: MenuBarFormat,
        sectionVisibility: SectionVisibility,
        selectedServerID: String?,
        selectedLibraryID: String?,
        loudnessLevelingEnabled: Bool,
        listenedThresholdPercentage: Int,
        themePreference: AppThemePreference
    ) {
        self.menuBarFormat = menuBarFormat
        self.sectionVisibility = sectionVisibility
        self.selectedServerID = selectedServerID
        self.selectedLibraryID = selectedLibraryID
        self.loudnessLevelingEnabled = loudnessLevelingEnabled
        self.listenedThresholdPercentage = listenedThresholdPercentage
        self.themePreference = themePreference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBarFormat = try container.decode(MenuBarFormat.self, forKey: .menuBarFormat)
        sectionVisibility = try container.decode(SectionVisibility.self, forKey: .sectionVisibility)
        selectedServerID = try container.decodeIfPresent(String.self, forKey: .selectedServerID)
        selectedLibraryID = try container.decodeIfPresent(String.self, forKey: .selectedLibraryID)
        loudnessLevelingEnabled = try container.decodeIfPresent(Bool.self, forKey: .loudnessLevelingEnabled) ?? false
        listenedThresholdPercentage = min(max(try container.decodeIfPresent(Int.self, forKey: .listenedThresholdPercentage) ?? 90, 50), 100)
        themePreference = try container.decodeIfPresent(AppThemePreference.self, forKey: .themePreference) ?? .system
    }

    static let `default` = AppSettings(
        menuBarFormat: .default,
        sectionVisibility: .default,
        selectedServerID: nil,
        selectedLibraryID: nil,
        loudnessLevelingEnabled: false,
        listenedThresholdPercentage: 90,
        themePreference: .system
    )
}
