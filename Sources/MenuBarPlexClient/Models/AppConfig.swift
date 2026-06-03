import Foundation

enum ActiveMediaSource: String, Codable, CaseIterable, Identifiable {
    case unspecified
    case plex
    case navidrome
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unspecified: return "Select..."
        case .plex: return "Plex"
        case .navidrome: return "Navidrome"
        case .local: return "Local Files"
        }
    }
}

struct NavidromeServerConfig: Codable, Equatable {
    var name: String
    var url: String
    var publicUrl: String?
    var username: String

    /// Scoped key for Keychain: "navidrome.SERVERNAME"
    var keychainKey: String {
        "navidrome." + name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
    }

    var isFilled: Bool {
        !name.isEmpty && !url.isEmpty && !username.isEmpty
    }

    static let `default` = NavidromeServerConfig(
        name: "",
        url: "",
        publicUrl: nil,
        username: ""
    )
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

enum PanelPositionPreference: String, CaseIterable, Codable, Identifiable {
    case screenCorner
    case menuBarItem

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screenCorner:
            return "Screen Corner"
        case .menuBarItem:
            return "Menu Bar Item"
        }
    }
}

struct DisplaySettings: Codable, Equatable {
    var menuBarFormat: MenuBarFormat
    var sectionVisibility: SectionVisibility
    var themePreference: AppThemePreference
    var panelPosition: PanelPositionPreference

    private enum CodingKeys: String, CodingKey {
        case menuBarFormat
        case sectionVisibility
        case themePreference
        case panelPosition
    }

    static let `default` = DisplaySettings(
        menuBarFormat: .default,
        sectionVisibility: .default,
        themePreference: .system,
        panelPosition: .screenCorner
    )

    init(
        menuBarFormat: MenuBarFormat,
        sectionVisibility: SectionVisibility,
        themePreference: AppThemePreference,
        panelPosition: PanelPositionPreference
    ) {
        self.menuBarFormat = menuBarFormat
        self.sectionVisibility = sectionVisibility
        self.themePreference = themePreference
        self.panelPosition = panelPosition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBarFormat = try container.decodeIfPresent(MenuBarFormat.self, forKey: .menuBarFormat) ?? .default
        sectionVisibility = try container.decodeIfPresent(SectionVisibility.self, forKey: .sectionVisibility) ?? .default
        themePreference = try container.decodeIfPresent(AppThemePreference.self, forKey: .themePreference) ?? .system
        panelPosition = try container.decodeIfPresent(PanelPositionPreference.self, forKey: .panelPosition) ?? .screenCorner
    }
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
    var mediaSource: ActiveMediaSource
    var navidromeConfig: NavidromeServerConfig

    private enum CodingKeys: String, CodingKey {
        case display
        case server
        case playback
        case mediaSource
        case navidromeConfig
    }

    init(display: DisplaySettings, server: ServerSettings, playback: PlaybackSettings) {
        self.display = display
        self.server = server
        self.playback = playback
        self.mediaSource = .unspecified
        self.navidromeConfig = .default
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
                    ?? .system,
                panelPosition: .screenCorner
            )
        }
        self.server = try container.decodeIfPresent(ServerSettings.self, forKey: .server) ?? .default
        self.playback = try container.decodeIfPresent(PlaybackSettings.self, forKey: .playback) ?? .default
        self.mediaSource = try container.decodeIfPresent(ActiveMediaSource.self, forKey: .mediaSource) ?? .unspecified
        self.navidromeConfig = try container.decodeIfPresent(NavidromeServerConfig.self, forKey: .navidromeConfig) ?? .default
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
    var panelPosition: PanelPositionPreference {
        get { display.panelPosition }
        set { display.panelPosition = newValue }
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
