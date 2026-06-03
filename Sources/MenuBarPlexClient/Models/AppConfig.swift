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

struct DisplaySettings: Codable, Equatable {
    var menuBarFormat: MenuBarFormat
    var sectionVisibility: SectionVisibility
    var themePreference: AppThemePreference

    static let `default` = DisplaySettings(
        menuBarFormat: .default,
        sectionVisibility: .default,
        themePreference: .system
    )
}

struct ServerSettings: Codable, Equatable {
    var selectedServerID: String?
    var selectedLibraryID: String?

    static let `default` = ServerSettings(
        selectedServerID: nil,
        selectedLibraryID: nil
    )
}

struct PlaybackSettings: Codable, Equatable {
    var loudnessLevelingEnabled: Bool
    var listenedThresholdPercentage: Int

    static let `default` = PlaybackSettings(
        loudnessLevelingEnabled: false,
        listenedThresholdPercentage: 90
    )
}

struct AppSettings: Codable, Equatable {
    var display: DisplaySettings
    var server: ServerSettings
    var playback: PlaybackSettings

    private enum CodingKeys: String, CodingKey {
        case display
        case server
        case playback
    }

    init(display: DisplaySettings, server: ServerSettings, playback: PlaybackSettings) {
        self.display = display
        self.server = server
        self.playback = playback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let display = try? container.decode(DisplaySettings.self, forKey: .display) {
            self.display = display
        } else {
            self.display = DisplaySettings(
                menuBarFormat: try container.decodeIfPresent(MenuBarFormat.self, forKey: .display)
                    ?? .default,
                sectionVisibility: try container.decodeIfPresent(SectionVisibility.self, forKey: .display)
                    ?? .default,
                themePreference: try container.decodeIfPresent(AppThemePreference.self, forKey: .display)
                    ?? .system
            )
        }
        self.server = try container.decodeIfPresent(ServerSettings.self, forKey: .server) ?? .default
        self.playback = try container.decodeIfPresent(PlaybackSettings.self, forKey: .playback) ?? .default
    }

    static let `default` = AppSettings(
        display: .default,
        server: .default,
        playback: .default
    )
}

// Backward-compatible property forwarding
extension AppSettings {
    var menuBarFormat: MenuBarFormat {
        get { display.menuBarFormat }
        set { display.menuBarFormat = newValue }
    }
    var sectionVisibility: SectionVisibility {
        get { display.sectionVisibility }
        set { display.sectionVisibility = newValue }
    }
    var themePreference: AppThemePreference {
        get { display.themePreference }
        set { display.themePreference = newValue }
    }
    var selectedServerID: String? {
        get { server.selectedServerID }
        set { server.selectedServerID = newValue }
    }
    var selectedLibraryID: String? {
        get { server.selectedLibraryID }
        set { server.selectedLibraryID = newValue }
    }
    var loudnessLevelingEnabled: Bool {
        get { playback.loudnessLevelingEnabled }
        set { playback.loudnessLevelingEnabled = newValue }
    }
    var listenedThresholdPercentage: Int {
        get { playback.listenedThresholdPercentage }
        set { playback.listenedThresholdPercentage = newValue }
    }
}
