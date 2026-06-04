import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            persist(settings)
        }
    }

    private let defaults: UserDefaults
    private let activeProfileKey = "app.settings.activeProfileKey"
    private let profilePrefix = "app.settings.profile."
    private var currentProfileKey: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        currentProfileKey = defaults.string(forKey: activeProfileKey)

        if let currentProfileKey,
           let decoded = Self.loadSettings(for: currentProfileKey, defaults: defaults, profilePrefix: profilePrefix) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    func switchProfile(to key: String, seed: AppSettings? = nil) {
        let sanitizedKey = Self.sanitizedProfileKey(key)
        guard currentProfileKey != sanitizedKey else { return }

        currentProfileKey = sanitizedKey
        defaults.set(sanitizedKey, forKey: activeProfileKey)

        if let profileSettings = Self.loadSettings(for: sanitizedKey, defaults: defaults, profilePrefix: profilePrefix) {
            settings = profileSettings
        } else {
            settings = seed ?? .default
        }
    }

    private func persist(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        guard let currentProfileKey else { return }
        defaults.set(data, forKey: profilePrefix + currentProfileKey)
    }

    private static func loadSettings(for key: String, defaults: UserDefaults, profilePrefix: String) -> AppSettings? {
        guard let data = defaults.data(forKey: profilePrefix + key) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func plexProfileKey(username: String) -> String {
        "plex-\(sanitizedProfileKey(username))"
    }

    static func navidromeProfileKey(connectionName: String) -> String {
        "navidrome-\(sanitizedProfileKey(connectionName))"
    }

    static func sanitizedProfileKey(_ value: String) -> String {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? "default" : sanitized
    }
}
