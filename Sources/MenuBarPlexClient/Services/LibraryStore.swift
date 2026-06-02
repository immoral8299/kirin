import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published var recentlyPlayedAlbums: [PlexAlbum] = []
    @Published var recentlyAddedAlbums: [PlexAlbum] = []
    @Published var playlists: [PlexPlaylist] = []
    @Published var stations: [PlexStation] = []
    @Published var isLoadingLibrary = false {
        didSet {
            if !isLoadingLibrary, oldValue, libraryLoadError == nil,
               context.playbackEngine?.currentTrack == nil {
                Task {
                    await ensureLastPlayedTrack()
                }
            }
        }
    }
    @Published var libraryLoadError: String?
    @Published var availableServers: [PlexServer] = []
    @Published var availableLibraries: [PlexMusicLibrary] = []
    @Published var currentLoadingMessage: String?
    @Published var shouldPresentInitialLoadFailure = false
    @Published var relatedAlbums: [PlexAlbum] = []

    private let context: StoreContext
    private let homeFetchLimit = 12
    private var relatedAlbumsTask: Task<Void, Never>?
    private var relatedAlbumsRatingKey: String?

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
        selectedServer?.name
    }

    var selectedLibraryTitle: String? {
        selectedLibrary?.title
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
        context.plexService.isAuthenticated && !availableServers.isEmpty && selectedServer == nil
    }

    var selectedServer: PlexServer? {
        if let selectedID = context.settingsStore.settings.selectedServerID,
           let server = availableServers.first(where: { $0.id == selectedID }) {
            return server
        }
        return nil
    }

    var selectedLibrary: PlexMusicLibrary? {
        guard !availableLibraries.isEmpty else { return nil }
        if let selectedID = context.settingsStore.settings.selectedLibraryID,
           let library = availableLibraries.first(where: { $0.id == selectedID }) {
            return library
        }
        return availableLibraries.first
    }

    var currentLoadingStatusLine: String {
        if let currentLoadingMessage {
            return currentLoadingMessage
        }
        return "Loading library..."
    }

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
        Task {
            await reloadHomeContentForSelection()
        }
    }

    func refreshServersAndLibraries() {
        Task {
            await refreshCurrentSelection()
        }
    }

    func dismissLibraryLoadError() {
        libraryLoadError = nil
    }

    func didPresentInitialLoadFailure() {
        shouldPresentInitialLoadFailure = false
    }

    func reloadPlexData() async {
        guard let userToken = context.plexService.authService.authToken else { return }

        startDebugLog("Reloading Plex data")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching Plex servers")
            let servers = try await context.plexService.fetchServers(userToken: userToken)
            availableServers = servers
            logDebug("Found \(servers.count) server(s)")

            guard let server = resolveServer(from: servers) else {
                context.settingsStore.settings.selectedServerID = nil
                context.settingsStore.settings.selectedLibraryID = nil
                availableLibraries = []
                throw PlexAPIError.serverSelectionRequired
            }

            context.settingsStore.settings.selectedServerID = server.id
            logDebug("Using server: \(server.name)")

            logDebug("Fetching music libraries")
            let libraries = try await context.plexService.fetchMusicLibraries(server: server, userToken: userToken)
            availableLibraries = libraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            context.settingsStore.settings.selectedLibraryID = library.id
            logDebug("Using library: \(library.title)")

            try await loadLibraryContent(server: server, library: library, userToken: userToken)
            logDebug("Library load completed")
        } catch {
            libraryLoadError = error.localizedDescription
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
        relatedAlbumsRatingKey = nil
    }

    func refreshRelatedAlbums(for track: PlexTrack) {
        guard relatedAlbumsRatingKey != track.albumRatingKey || relatedAlbums.isEmpty else { return }

        relatedAlbumsTask?.cancel()
        relatedAlbums = []
        relatedAlbumsRatingKey = track.albumRatingKey

        guard let albumRatingKey = track.albumRatingKey,
              let server = selectedServer,
              let userToken = context.plexService.authService.authToken else {
            return
        }

        relatedAlbumsTask = Task {
            do {
                let albums = try await context.plexService.fetchRelatedAlbums(
                    server: server,
                    albumRatingKey: albumRatingKey,
                    userToken: userToken
                )
                guard !Task.isCancelled else { return }
                relatedAlbums = albums
            } catch {
                guard !Task.isCancelled else { return }
                logDebug("Related albums lookup failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    private func reloadLibrariesAndContentForSelectedServer(id: String) async {
        guard let userToken = context.plexService.authService.authToken,
              let selectedServer = availableServers.first(where: { $0.id == id }) else {
            return
        }

        startDebugLog("Switching server")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching libraries for \(selectedServer.name)")
            let libraries = try await context.plexService.fetchMusicLibraries(server: selectedServer, userToken: userToken)
            guard selectedServerID == selectedServer.id else { return }

            availableLibraries = libraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            context.settingsStore.settings.selectedLibraryID = library.id
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: selectedServer, library: library, userToken: userToken)
            logDebug("Server switch completed")
        } catch {
            libraryLoadError = error.localizedDescription
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func reloadHomeContentForSelection() async {
        guard let userToken = context.plexService.authService.authToken,
              let server = selectedServer,
              let library = selectedLibrary else {
            return
        }

        startDebugLog("Switching library")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Using server: \(server.name)")
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: server, library: library, userToken: userToken)
            logDebug("Library switch completed")
        } catch {
            libraryLoadError = error.localizedDescription
            logDebug("Load failed: \(error.localizedDescription)")
        }

        isLoadingLibrary = false
        currentLoadingMessage = nil
    }

    private func refreshCurrentSelection() async {
        guard let userToken = context.plexService.authService.authToken else { return }

        startDebugLog("Refreshing current library")
        isLoadingLibrary = true
        libraryLoadError = nil

        do {
            logDebug("Fetching Plex servers")
            let servers = try await context.plexService.fetchServers(userToken: userToken)
            availableServers = servers
            logDebug("Found \(servers.count) server(s)")

            guard let server = resolveServer(from: servers) else {
                context.settingsStore.settings.selectedServerID = nil
                context.settingsStore.settings.selectedLibraryID = nil
                availableLibraries = []
                throw PlexAPIError.serverSelectionRequired
            }

            context.settingsStore.settings.selectedServerID = server.id
            logDebug("Using server: \(server.name)")

            logDebug("Fetching music libraries")
            let libraries = try await context.plexService.fetchMusicLibraries(server: server, userToken: userToken)
            availableLibraries = libraries
            logDebug("Found \(libraries.count) library/libraries")

            guard let library = resolveLibrary(from: libraries) else {
                throw PlexAPIError.invalidResponse
            }

            context.settingsStore.settings.selectedLibraryID = library.id
            logDebug("Using library: \(library.title)")
            try await loadLibraryContent(server: server, library: library, userToken: userToken)
            logDebug("Refresh completed")
        } catch {
            libraryLoadError = error.localizedDescription
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
        let homeContent = try await context.plexService.fetchHomeContent(
            server: server,
            library: library,
            userToken: userToken,
            limit: homeFetchLimit
        )

        recentlyPlayedAlbums = homeContent.recentlyPlayedAlbums
        recentlyAddedAlbums = homeContent.recentlyAddedAlbums
        playlists = homeContent.playlists
        stations = homeContent.stations
        logDebug("Loaded \(recentlyPlayedAlbums.count) recent played, \(recentlyAddedAlbums.count) recent added, \(playlists.count) playlists, \(stations.count) stations")
    }

    private func ensureLastPlayedTrack() async {
        guard let lastAlbum = recentlyPlayedAlbums.first,
              let server = selectedServer,
              let userToken = context.plexService.authService.authToken else {
            return
        }

        context.playbackEngine?.resetForNewTrack()

        do {
            let tracks = try await context.plexService.fetchAlbumTracks(server: server, album: lastAlbum, userToken: userToken)
            guard let firstTrack = tracks.first else {
                logDebug("No tracks found in last played album")
                return
            }
            context.playbackEngine?.preparePreviewTrack(firstTrack)
            logDebug("Prepared last played track: \(firstTrack.title)")
        } catch {
            logDebug("Last played album track lookup failed: \(error.localizedDescription)")
        }
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

    private func logDebug(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
    }

    private func stripDebugTimestamp(from line: String) -> String {
        guard let closingBracketIndex = line.firstIndex(of: "]") else {
            return line
        }
        return line[line.index(after: closingBracketIndex)...].trimmingCharacters(in: .whitespaces)
    }
}
