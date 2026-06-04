import Foundation

struct ReleaseManifest: Codable, Equatable {
    let appName: String
    let version: String
    let tag: String
    let releaseDate: String
    let downloadURL: URL
    let pageURL: URL
}

enum UpdateEndpoints {
    static let releaseManifest = URL(string: "https://immoral8299.github.io/kirin/release.json")!
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate(ReleaseManifest)
    case updateAvailable(ReleaseManifest)
    case informational(ReleaseManifest)
    case failed(String)
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var state: UpdateCheckState = .idle
    @Published private(set) var lastCheckDate: Date?

    private let manifestURL: URL
    private let session: URLSession
    private let bundle: Bundle
    private let defaults: UserDefaults
    private let lastCheckDateKey = "app.updateChecker.lastCheckDate"
    private let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    init(
        manifestURL: URL = UpdateEndpoints.releaseManifest,
        session: URLSession = .shared,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        self.manifestURL = manifestURL
        self.session = session
        self.bundle = bundle
        self.defaults = defaults
        self.lastCheckDate = defaults.object(forKey: lastCheckDateKey) as? Date
    }

    var hasUpdateAvailable: Bool {
        if case .updateAvailable = state {
            return true
        }
        return false
    }

    var currentVersion: String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var currentVersionDisplay: String {
        guard let currentVersion,
              !currentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Development"
        }
        return "v\(currentVersion.trimmingLeadingVersionPrefix())"
    }

    func checkForUpdatesIfNeeded() async {
        guard shouldRunAutomaticCheck else { return }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard state != .checking else { return }
        state = .checking
        defer { markLastCheckDate() }

        do {
            let (data, response) = try await session.data(from: manifestURL)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                state = .failed("Update check failed with HTTP \(httpResponse.statusCode).")
                return
            }

            let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
            guard let currentVersion,
                  !currentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .informational(manifest)
                return
            }

            if Self.compareVersions(manifest.version, currentVersion) == .orderedDescending {
                state = .updateAvailable(manifest)
            } else {
                state = .upToDate(manifest)
            }
        } catch {
            state = .failed("Could not check for updates. Please try again.")
        }
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = versionParts(lhs)
        let rhsParts = versionParts(rhs)
        let maxCount = max(lhsParts.count, rhsParts.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0

            if lhsValue < rhsValue { return .orderedAscending }
            if lhsValue > rhsValue { return .orderedDescending }
        }

        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .trimmingLeadingVersionPrefix()
            .split(separator: ".")
            .map { part in
                let numericPrefix = part.prefix { $0.isNumber }
                return Int(numericPrefix) ?? 0
            }
    }

    private var shouldRunAutomaticCheck: Bool {
        guard let lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheckDate) >= automaticCheckInterval
    }

    private func markLastCheckDate() {
        let date = Date()
        lastCheckDate = date
        defaults.set(date, forKey: lastCheckDateKey)
    }
}

private extension String {
    func trimmingLeadingVersionPrefix() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("v") else { return trimmed }
        return String(trimmed.dropFirst())
    }
}
