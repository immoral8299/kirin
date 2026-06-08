import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published var recentlyPlayedAlbums: [MediaAlbum] = []
    @Published var recentlyAddedAlbums: [MediaAlbum] = []
    @Published var playlists: [MediaPlaylist] = []
    @Published var stations: [MediaStation] = []
    @Published var isLoadingLibrary = false
    @Published var libraryLoadError: LibraryLoadError?
    @Published var availableServers: [MediaServer] = []
    @Published var availableLibraries: [MediaMusicLibrary] = []
    @Published var currentLoadingMessage: String?
    @Published var shouldPresentInitialLoadFailure = false
    @Published var relatedAlbums: [MediaAlbum] = []
    @Published var queueStationRecommendations: [MediaStationRecommendation] = []

    private let context: StoreContext
    private var relatedAlbumsTask: Task<Void, Never>?
    private var relatedAlbumsTrackID: String?
    private var queueStationRecommendationsTask: Task<Void, Never>?
    private var queueStationRecommendationSeedIDs: [String] = []
    private var queueStationRecommendationsGeneration = 0

    private var plexService: PlexService? { context.plexService }

    init(context: StoreContext) {
        self.context = context
    }

    var selectedServerID: String? {
        context.settingsStore.settings.selectedServerID
    }

    var selectedLibraryID: String? {
        context.settingsStore.settings.selectedLibraryID
    }

    var selectedServerName: String? {
        if let server = selectedPlexServer {
            return server.name
        }
        if context.mediaService is NavidromeService {
            return availableServers.first?.name
        }
        if context.mediaService is LocalService {
            return "Local Files"
        }
        return nil
    }

    var selectedLibraryTitle: String? {
        if let library = selectedPlexLibrary {
            return library.title
        }
        if context.mediaService is NavidromeService {
            return availableLibraries.first?.title
        }
        if context.mediaService is LocalService {
            return "Files"
        }
        return nil
    }

    var hasExistingContent: Bool {
        !recentlyPlayedAlbums.isEmpty || !recentlyAddedAlbums.isEmpty || !playlists.isEmpty || !stations.isEmpty
    }

    var loadingTargetDescription: String? {
        guard let serverName = selectedServerName, let libraryTitle = selectedLibraryTitle else {
            return nil
        }
        return "\(serverName) / \(libraryTitle)"
    }

    var shouldPromptForServerSelection: Bool {
        guard context.plexService != nil else { return false }
        return context.mediaService.isAuthenticated && !availableServers.isEmpty && selectedPlexServer == nil
    }

    var selectedPlexServer: PlexServer? {
        guard let plexService,
              let server = plexService.plexServers.first(where: { $0.id == context.settingsStore.settings.selectedServerID }) else {
            return nil
        }
        return server
    }

    var selectedPlexLibrary: PlexMusicLibrary? {
        guard let plexService, selectedPlexServer != nil else { return nil }
        let libraries = plexService.plexLibraries
        guard !libraries.isEmpty else { return nil }
        if let selectedID = context.settingsStore.settings.selectedLibraryID,
           let library = libraries.first(where: { $0.id == selectedID }) {
            return library
        }
        return libraries.first
    }

    var currentLoadingStatusLine: String {
        if let currentLoadingMessage {
            return currentLoadingMessage
        }
        return "Loading library..."
    }

    // MARK: - Source-agnostic reload (works for Plex and Navidrome)

    func reloadData() async {
        isLoadingLibrary = true
        libraryLoadError = nil
        availableServers = context.mediaService.availableServers
        availableLibraries = context.mediaService.availableLibraries
        startDebugLog("Loading content")

        do {
            let homeContent = try await context.mediaService.fetchHomeContent(limit: LibraryConfiguration.homeFetchLimit)
            setHomeContent(homeContent)
            clearSuccessfulLoadState()
            logDebug("Loaded \(recentlyPlayedAlbums.count) recent played, \(recentlyAddedAlbums.count) recent added, \(playlists.count) playlists, \(stations.count) stations")
        } catch {
            libraryLoadError = LibraryLoadError(error)
            shouldPresentInitialLoadFailure = true
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    // MARK: - Plex-specific server/library selection

    func selectServer(id: String) {
        guard context.settingsStore.settings.selectedServerID != id else { return }
        context.settingsStore.settings.selectedServerID = id
        context.settingsStore.settings.selectedLibraryID = nil
        availableLibraries = []
        Task {
            await reloadLibrariesAndContentForSelectedServer(id: id)
        }
    }

    func selectLibrary(id: String) {
        guard context.settingsStore.settings.selectedLibraryID != id else { return }
        context.settingsStore.settings.selectedLibraryID = id
        Task {
            await reloadHomeContentForSelection()
        }
    }

    func refreshCurrentLibraryContent() {
        guard context.mediaService is LocalService == false else { return }
        Task {
            if context.plexService != nil {
                await reloadHomeContentForSelection()
            } else {
                await reloadData()
            }
        }
    }

    func refreshServersAndLibraries() {
        guard context.mediaService is LocalService == false else { return }
        Task {
            if context.plexService != nil {
                await refreshCurrentSelection()
            } else {
                await reloadData()
            }
        }
    }

    func dismissLibraryLoadError() {
        libraryLoadError = nil
    }

    func didPresentInitialLoadFailure() {
        shouldPresentInitialLoadFailure = false
    }

    func reloadPlexData() async {
        guard let plexService,
              let userToken = plexService.authService.authToken else { return }

        startDebugLog("Reloading Plex data")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching Plex servers")
            let servers = try await plexService.fetchServers(userToken: userToken)
            plexService.plexServers = servers
            let mediaServers = servers.map(\.mediaServer)
            plexService.availableServers = mediaServers
            availableServers = mediaServers
            logDebug("Found \(servers.count) server(s)")

            guard let server = resolveServer(from: servers) else {
                context.settingsStore.settings.selectedServerID = nil
                context.settingsStore.settings.selectedLibraryID = nil
                availableLibraries = []
                throw PlexAPIError.serverSelectionRequired
            }

            applyPlexSelection(server: server)
            logDebug("Using server: \(server.name)")

            logDebug("Fetching music libraries")
            let libraries = try await plexService.fetchMusicLibraries(server: server, userToken: userToken)
            plexService.plexLibraries = libraries
            let mediaLibraries = libraries.map(\.mediaMusicLibrary)
            plexService.availableLibraries = mediaLibraries
            availableLibraries = mediaLibraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            applyPlexSelection(library: library)
            logDebug("Using library: \(library.title)")

            try await loadLibraryContent(server: server, library: library, userToken: userToken)
            clearSuccessfulLoadState()
            logDebug("Library load completed")
        } catch {
            libraryLoadError = LibraryLoadError(error)
            shouldPresentInitialLoadFailure = true
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    func resetPlaybackPreview() {
        relatedAlbumsTask?.cancel()
        relatedAlbumsTask = nil
        relatedAlbums = []
        relatedAlbumsTrackID = nil
        resetQueueStationRecommendations()
    }

    func resetContent() {
        recentlyPlayedAlbums = []
        recentlyAddedAlbums = []
        playlists = []
        stations = []
        availableServers = []
        availableLibraries = []
        libraryLoadError = nil
        currentLoadingMessage = nil
        shouldPresentInitialLoadFailure = false
        resetPlaybackPreview()
    }

    func refreshRelatedAlbums(for track: MediaTrack) {
        guard context.mediaService is LocalService == false else {
            relatedAlbumsTask?.cancel()
            relatedAlbumsTask = nil
            relatedAlbums = []
            relatedAlbumsTrackID = nil
            return
        }

        let albumID = track.albumRatingKey ?? track.id
        guard relatedAlbumsTrackID != albumID || relatedAlbums.isEmpty else { return }

        relatedAlbumsTask?.cancel()
        relatedAlbumsTrackID = albumID

        relatedAlbumsTask = Task {
            do {
                let albums = try await context.mediaService.fetchRelatedAlbums(
                    albumRatingKey: albumID,
                    limit: LibraryConfiguration.relatedAlbumsLimit
                )
                guard !Task.isCancelled else { return }
                relatedAlbums = albums
                if albums.isEmpty {
                    logDebug("No related albums found for album \(albumID)")
                }
            } catch {
                guard !Task.isCancelled else { return }
                logDebug("Related albums lookup failed: \(error.localizedDescription)")
            }
        }
    }

    func refreshQueueStationRecommendations(for tracks: [MediaTrack]) {
        guard let plexService,
              let server = selectedPlexServer,
              let userToken = plexService.authService.authToken else {
            queueStationRecommendations = []
            return
        }

        let artistSeeds = uniqueArtistSeeds(from: tracks, plexService: plexService, server: server, userToken: userToken)
        let albumSeeds = uniqueAlbumSeeds(from: tracks)
        let seedIDs = artistSeeds.map { "artist-\($0.id)" } + albumSeeds.map { "album-\($0.id)" }

        guard seedIDs != queueStationRecommendationSeedIDs else { return }

        queueStationRecommendationsTask?.cancel()
        queueStationRecommendationSeedIDs = seedIDs
        queueStationRecommendationsGeneration += 1
        let generation = queueStationRecommendationsGeneration

        guard !seedIDs.isEmpty else { return }

        queueStationRecommendationsTask = Task {
            var recommendations: [MediaStationRecommendation] = []

            for seed in artistSeeds {
                guard !Task.isCancelled else { return }
                do {
                    if let station = try await plexService.fetchArtistStation(
                        server: server,
                        artistRatingKey: seed.id,
                        userToken: userToken
                    ) {
                        recommendations.append(seed.recommendation(kind: .artist, station: station.mediaStation))
                    }
                } catch {
                    logDebug("Artist station lookup failed: \(error.localizedDescription)")
                }
            }

            for seed in albumSeeds {
                guard !Task.isCancelled else { return }
                recommendations.append(seed.recommendation(kind: .album))
            }

            guard !Task.isCancelled, generation == queueStationRecommendationsGeneration else { return }
            queueStationRecommendations = recommendations
        }
    }

    func resetQueueStationRecommendations() {
        queueStationRecommendationsTask?.cancel()
        queueStationRecommendationsTask = nil
        queueStationRecommendations = []
        queueStationRecommendationSeedIDs = []
        queueStationRecommendationsGeneration += 1
    }

    // MARK: - Private

    private struct QueueStationSeed {
        let id: String
        let title: String
        let artworkURL: URL?

        func recommendation(kind: MediaStationRecommendationKind, station: MediaStation? = nil) -> MediaStationRecommendation {
            MediaStationRecommendation(
                kind: kind,
                seedID: id,
                title: title,
                subtitle: kind == .artist ? "Artist Radio" : "Album Radio",
                artworkURL: artworkURL,
                station: station
            )
        }
    }

    private func uniqueArtistSeeds(from tracks: [MediaTrack], plexService: PlexService, server: PlexServer, userToken: String) -> [QueueStationSeed] {
        var seenIDs = Set<String>()
        return tracks.compactMap { track -> QueueStationSeed? in
            guard seenIDs.count < LibraryConfiguration.artistStationSeedLimit,
                  let id = track.artistRatingKey,
                  seenIDs.insert(id).inserted else {
                return nil
            }

            let artistArtworkURL: URL? = plexArtworkURL(from: "/library/metadata/\(id)/thumb", server: server, token: userToken)

            return QueueStationSeed(
                id: id,
                title: track.albumArtist ?? track.trackArtist ?? "Unknown Artist",
                artworkURL: artistArtworkURL
            )
        }
    }

    private func uniqueAlbumSeeds(from tracks: [MediaTrack]) -> [QueueStationSeed] {
        var seenIDs = Set<String>()
        return tracks.compactMap { track -> QueueStationSeed? in
            guard seenIDs.count < LibraryConfiguration.artistStationSeedLimit,
                  let id = track.albumRatingKey,
                  seenIDs.insert(id).inserted else {
                return nil
            }

            return QueueStationSeed(id: id, title: track.albumName, artworkURL: track.artworkURL)
        }
    }

    private func reloadLibrariesAndContentForSelectedServer(id: String) async {
        guard let plexService,
              let userToken = plexService.authService.authToken,
              let selectedServer = plexService.plexServers.first(where: { $0.id == id }) else {
            return
        }

        startDebugLog("Switching server")
        isLoadingLibrary = true
        libraryLoadError = nil
        applyPlexSelection(server: selectedServer)

        do {
            logDebug("Fetching libraries for \(selectedServer.name)")
            let libraries = try await plexService.fetchMusicLibraries(server: selectedServer, userToken: userToken)
            plexService.plexLibraries = libraries
            let mediaLibraries = libraries.map(\.mediaMusicLibrary)
            plexService.availableLibraries = mediaLibraries
            guard selectedServerID == selectedServer.id else { return }

            availableLibraries = mediaLibraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            applyPlexSelection(library: library)
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: selectedServer, library: library, userToken: userToken)
            clearSuccessfulLoadState()
            logDebug("Server switch completed")
        } catch {
            libraryLoadError = LibraryLoadError(error)
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func reloadHomeContentForSelection() async {
        guard let plexService,
              let userToken = plexService.authService.authToken,
              let server = selectedPlexServer,
              let library = selectedPlexLibrary else {
            return
        }

        startDebugLog("Switching library")
        isLoadingLibrary = true
        libraryLoadError = nil
        applyPlexSelection(server: server, library: library)

        do {
            logDebug("Using server: \(server.name)")
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: server, library: library, userToken: userToken)
            clearSuccessfulLoadState()
            logDebug("Library switch completed")
        } catch {
            libraryLoadError = LibraryLoadError(error)
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func refreshCurrentSelection() async {
        guard let plexService,
              let userToken = plexService.authService.authToken else { return }

        startDebugLog("Refreshing current library")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching Plex servers")
            let servers = try await plexService.fetchServers(userToken: userToken)
            plexService.plexServers = servers
            let mediaServers = servers.map(\.mediaServer)
            plexService.availableServers = mediaServers
            availableServers = mediaServers
            logDebug("Found \(servers.count) server(s)")

            guard let server = resolveServer(from: servers) else {
                context.settingsStore.settings.selectedServerID = nil
                context.settingsStore.settings.selectedLibraryID = nil
                availableLibraries = []
                throw PlexAPIError.serverSelectionRequired
            }

            applyPlexSelection(server: server)
            logDebug("Using server: \(server.name)")

            logDebug("Fetching music libraries")
            let libraries = try await plexService.fetchMusicLibraries(server: server, userToken: userToken)
            plexService.plexLibraries = libraries
            let mediaLibraries = libraries.map(\.mediaMusicLibrary)
            plexService.availableLibraries = mediaLibraries
            availableLibraries = mediaLibraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            applyPlexSelection(library: library)
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: server, library: library, userToken: userToken)
            clearSuccessfulLoadState()
            logDebug("Refresh completed")
        } catch {
            libraryLoadError = LibraryLoadError(error)
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func loadLibraryContent(server: PlexServer, library: PlexMusicLibrary, userToken: String) async throws {
        logDebug("Fetching home content")
        try await reloadHomeContent(server: server, library: library, userToken: userToken)
    }

    private func reloadHomeContent(server: PlexServer, library: PlexMusicLibrary, userToken: String) async throws {
        guard let plexService else { return }
        let homeContent = try await plexService.fetchHomeContent(
            server: server,
            library: library,
            userToken: userToken,
            limit: LibraryConfiguration.homeFetchLimit
        )

        setHomeContent(homeContent.mediaHomeContent)
        logDebug("Loaded \(recentlyPlayedAlbums.count) recent played, \(recentlyAddedAlbums.count) recent added, \(playlists.count) playlists, \(stations.count) stations")
    }

    private func setHomeContent(_ content: MediaHomeContent) {
        recentlyPlayedAlbums = content.recentlyPlayedAlbums
        recentlyAddedAlbums = content.recentlyAddedAlbums
        playlists = content.playlists
        stations = content.stations
    }

    private func applyPlexSelection(server: PlexServer? = nil, library: PlexMusicLibrary? = nil) {
        if let server {
            context.settingsStore.settings.selectedServerID = server.id
            plexService?.selectedServerID = server.id
        }

        if let library {
            context.settingsStore.settings.selectedLibraryID = library.id
            plexService?.selectedLibraryID = library.id
        }
    }

    private func clearSuccessfulLoadState() {
        libraryLoadError = nil
        shouldPresentInitialLoadFailure = false
    }

    private func resolveServer(from servers: [PlexServer]) -> PlexServer? {
        if let selectedID = context.settingsStore.settings.selectedServerID,
           let server = servers.first(where: { $0.id == selectedID }) {
            return server
        }
        return nil
    }

    private func resolveLibrary(from libraries: [PlexMusicLibrary]) -> PlexMusicLibrary? {
        if let selectedID = context.settingsStore.settings.selectedLibraryID,
           let library = libraries.first(where: { $0.id == selectedID }) {
            return library
        }
        return libraries.first
    }

    private func startDebugLog(_ message: String) {
        currentLoadingMessage = stripDebugTimestamp(from: message)
        logDebug(message)
    }

    private enum LibraryConfiguration {
        static let homeFetchLimit = 12
        static let relatedAlbumsLimit = 4
        static let artistStationSeedLimit = 2
        static let albumRadioSimilarLimit = 4
    }

    private func logDebug(_ message: String) {
        PlexLog.debug(message, category: .library)
    }

    private func stripDebugTimestamp(from line: String) -> String {
        guard let closingBracketIndex = line.firstIndex(of: "]") else {
            return line
        }
        return line[line.index(after: closingBracketIndex)...].trimmingCharacters(in: .whitespaces)
    }
}
