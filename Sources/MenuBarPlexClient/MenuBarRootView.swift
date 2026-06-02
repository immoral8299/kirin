import AppKit
import SwiftUI

private enum MenuBarLayout {
    static let contentWidth: CGFloat = 432
    static let popupWidth: CGFloat = 460
    static let minPopupHeight: CGFloat = 400
}

private enum ContentTab {
    case home
    case queue
    case settings
}

struct MenuBarRootView: View {
    @ObservedObject var appState: AppState
    let onClose: () -> Void
    let onTabChange: (Bool) -> Void
    @State private var selectedTab: ContentTab = .home

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 14) {
                    scrollableContent
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .frame(width: MenuBarLayout.contentWidth, alignment: .top)
                .frame(maxWidth: .infinity, minHeight: MenuBarLayout.minPopupHeight, alignment: .top)
            }
        }
        .frame(width: MenuBarLayout.popupWidth)
        .frame(minHeight: MenuBarLayout.minPopupHeight)
        .background(
            LinearGradient(
                colors: [AppTheme.backgroundTop, AppTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.primary)
        .preferredColorScheme(appState.themePreference.colorScheme)
    }

    @ViewBuilder
    private var scrollableContent: some View {
        if appState.isAuthenticated {
            if appState.shouldPromptForServerSelection {
                ChooseServerCard(appState: appState)
            } else {
                activeLibraryBanner
                connectionBanner

                NowPlayingCard(
                    metadata: appState.nowPlaying,
                    playbackState: appState.playbackState,
                    playbackProgress: appState.playbackProgress,
                    playbackPosition: appState.playbackPosition,
                    playbackDuration: appState.playbackDuration,
                    isShuffleEnabled: appState.isShuffleEnabled,
                    onPlayPause: appState.togglePlayback,
                    onNext: appState.nextTrack,
                    onPrevious: appState.previousTrack,
                    onSeek: appState.seekToProgress,
                    onToggleShuffle: appState.toggleShuffle
                )
            }

            switch selectedTab {
            case .settings:
                SettingsView(appState: appState)
                    .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
                    .background(AppTheme.panelFillSoft, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            case .queue:
                if !appState.shouldPromptForServerSelection {
                    if !appState.relatedAlbums.isEmpty {
                        RelatedAlbumsSection(
                            albums: appState.relatedAlbums,
                            onSelect: appState.playAlbum,
                            onPlayNext: { appState.enqueueAlbum($0, playNext: true) },
                            onAddToQueue: { appState.enqueueAlbum($0, playNext: false) }
                        )
                    }
                    PlayQueueView(appState: appState)
                }
            case .home:
                if !appState.shouldPromptForServerSelection {
                    homeContent
                }
            }
        } else {
            LoginPromptCard(
                authState: appState.authService.status.state,
                onConnect: appState.beginPlexLogin,
                onOpenBrowser: appState.authService.reopenBrowser
            )
        }
    }

    @ViewBuilder
    private var homeContent: some View {
                let visibility = appState.settingsStore.settings.sectionVisibility

                if visibility.showRecentlyPlayedAlbums && !appState.recentlyPlayedAlbums.isEmpty {
                    AlbumCarouselSection(
                        title: "Recently Played",
                        items: appState.recentlyPlayedAlbums,
                        pageSize: 4,
                        onSelect: appState.playAlbum,
                        onPlayNext: { appState.enqueueAlbum($0, playNext: true) },
                        onAddToQueue: { appState.enqueueAlbum($0, playNext: false) }
                    )
                }

                if visibility.showRecentlyAddedAlbums && !appState.recentlyAddedAlbums.isEmpty {
                    AlbumCarouselSection(
                        title: "Recently Added",
                        items: appState.recentlyAddedAlbums,
                        pageSize: 4,
                        onSelect: appState.playAlbum,
                        onPlayNext: { appState.enqueueAlbum($0, playNext: true) },
                        onAddToQueue: { appState.enqueueAlbum($0, playNext: false) }
                    )
                }

                if visibility.showPlaylists && !appState.playlists.isEmpty {
                    PlaylistCarouselSection(
                        title: "Playlists",
                        items: appState.playlists,
                        pageSize: 4,
                        onSelect: appState.playPlaylist,
                        onPlayNext: { appState.enqueuePlaylist($0, playNext: true) },
                        onAddToQueue: { appState.enqueuePlaylist($0, playNext: false) }
                    )
                }

                if visibility.showStations && !appState.stations.isEmpty {
                    StationCarouselSection(
                        title: "Stations",
                        items: appState.stations,
                        pageSize: 4,
                        onSelect: appState.playStation,
                        onPlayNext: { appState.enqueueStation($0, playNext: true) },
                        onAddToQueue: { appState.enqueueStation($0, playNext: false) }
                    )
                }

                if !appState.isLoadingLibrary,
                   appState.recentlyPlayedAlbums.isEmpty,
                   appState.recentlyAddedAlbums.isEmpty,
                   appState.playlists.isEmpty,
                   appState.stations.isEmpty {
                    EmptyLibraryCard()
                }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .interactiveCursor()

            Text(tabTitle)
                .font(.system(size: 14, weight: .bold, design: .rounded))

            Spacer()

            authButton

            if appState.isAuthenticated {
                tabButton(.home, icon: "house", tooltip: "Home")
                tabButton(.queue, icon: "list.bullet", tooltip: "Play Queue")
                tabButton(.settings, icon: "gearshape", tooltip: "Settings")
            }
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }

    private var tabTitle: String {
        switch selectedTab {
        case .home:
            return "PlexTray"
        case .queue:
            return "PlexTray / Queue"
        case .settings:
            return "PlexTray / Settings"
        }
    }

    private func tabButton(_ tab: ContentTab, icon: String, tooltip: String) -> some View {
        Button {
            selectedTab = tab
            onTabChange(tab == .settings)
        } label: {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .background(selectedTab == tab ? AppTheme.overlayStrong : .clear, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .interactiveCursor()
        .foregroundStyle(selectedTab == tab ? AppTheme.accent : Color.secondary.opacity(0.8))
        .help(tooltip)
    }

    @ViewBuilder
    private var activeLibraryBanner: some View {
        if let serverName = appState.selectedServerName,
           let libraryTitle = appState.selectedLibraryTitle {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(AppTheme.accent)
                Text("\(serverName) / \(libraryTitle)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if appState.isLoadingLibrary, appState.hasExistingContent {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing...")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))
                }

                Button {
                    appState.refreshLibraryContent()
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .interactiveCursor()
            }
            .padding(8)
            .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
            .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if appState.isLoadingLibrary, !appState.hasExistingContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Plex library...")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }

                if let loadingTargetDescription = appState.loadingTargetDescription {
                    Text(loadingTargetDescription)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(8)
            .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
            .background(AppTheme.overlaySoft, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
        } else if let error = appState.libraryLoadError {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        appState.dismissLibraryLoadError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .interactiveCursor()
                    .foregroundStyle(.secondary.opacity(0.72))
                }
            }
            .padding(8)
            .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
            .background(AppTheme.overlayStrong, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
    }

    @ViewBuilder
    private var authButton: some View {
        switch appState.authService.status.state {
        case .authenticated:
            EmptyView()
        case .requestingPin, .waitingForBrowserLogin:
            ProgressView()
                .controlSize(.small)
        default:
            EmptyView()
        }
    }
}

private struct EmptyLibraryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Plex library is connected")
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text("No recent albums or playlists were returned for the selected library yet. Try another library in settings or refresh.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }
}

private struct ChooseServerCard: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(greetingTitle)
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Choose a Plex server to use as your default. You can change it later in settings.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.76))

            VStack(spacing: 8) {
                ForEach(appState.availableServers) { server in
                    Button {
                        appState.selectServer(id: server.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(AppTheme.accent)
                            Text(server.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .interactiveCursor(disabled: appState.isLoadingLibrary)
                    .disabled(appState.isLoadingLibrary)
                }
            }

            if let error = appState.libraryLoadError {
                Text(error)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }

    private var greetingTitle: String {
        if let username = appState.authenticatedUsername {
            return "Welcome, \(username)"
        }

        return "Welcome to PlexTray"
    }
}

private struct LoginPromptCard: View {
    let authState: PlexAuthStatus.State
    let onConnect: () -> Void
    let onOpenBrowser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your Plex account")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Sign in via your browser to load your server, music library, and playlists.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.78))

            switch authState {
            case .requestingPin:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Requesting Plex login PIN...")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            case let .waitingForBrowserLogin(_, code):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finish sign-in in your browser. Waiting for approval...")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }

                    Text("Code: \(code)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.75))

                    Button("Open Browser Again") {
                        onOpenBrowser()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .interactiveCursor()
                    .foregroundStyle(AppTheme.accent)
                }
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.yellow)
                    connectButton
                }
            default:
                connectButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }

    private var connectButton: some View {
        Button {
            onConnect()
        } label: {
            Label("Log in with Plex", systemImage: "person.badge.key")
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .interactiveCursor()
            .background(AppTheme.accent, in: Capsule())
            .foregroundStyle(AppTheme.onAccent)
        }
}

private struct NowPlayingCard: View {
    let metadata: TrackMetadata
    let playbackState: PlaybackState
    let playbackProgress: Double
    let playbackPosition: Double
    let playbackDuration: Double
    let isShuffleEnabled: Bool
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSeek: (Double) -> Void
    let onToggleShuffle: () -> Void
    @State private var sliderValue: Double = 0
    @State private var isSeeking = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkImage(url: metadata.artworkURL, placeholderSystemImage: "music.note.list")
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(metadata.trackName)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if let trackNumberLabel {
                                Text(trackNumberLabel)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.68))
                                    .lineLimit(1)
                            }
                        }
                        Text(metadata.resolvedTrackArtist)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.82))
                            .lineLimit(1)
                        Text(metadata.albumName)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.68))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 16) {
                        transportButton(icon: "backward.fill", action: onPrevious)
                        transportButton(
                            icon: playbackState.actionSystemImageName,
                            showsProgress: playbackState == .buffering,
                            action: onPlayPause
                        )
                        transportButton(icon: "forward.fill", action: onNext)
                        transportButton(icon: "shuffle", isActive: isShuffleEnabled, action: onToggleShuffle)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 128, alignment: .topLeading)
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isSeeking ? sliderValue : playbackProgress },
                        set: { newValue in
                            isSeeking = true
                            sliderValue = newValue
                            onSeek(newValue)
                        }
                    ),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        isSeeking = editing
                    }
                )
                .tint(AppTheme.accent)

                HStack {
                    Text(formattedTime(playbackPosition))
                    Spacer()
                    Text(formattedTime(playbackDuration))
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.68))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .onChange(of: playbackProgress) { _, newValue in
            if !isSeeking {
                sliderValue = newValue
            }
        }
    }

    private func transportButton(
        icon: String,
        isActive: Bool = false,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .offset(y: -1)
                }
            }
            .frame(width: 36, height: 36, alignment: .center)
            .background((isActive ? AppTheme.accentActiveBackground : AppTheme.transportFill), in: Circle())
        }
        .buttonStyle(.plain)
        .interactiveCursor()
        .foregroundStyle(isActive ? AppTheme.accent : Color.primary)
    }

    private var trackNumberLabel: String? {
        guard let trackNumber = metadata.trackNumber else { return nil }

        if let discNumber = metadata.discNumber {
            return "\(discNumber).\(trackNumber)"
        }

        return "Nr. \(trackNumber)"
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct AlbumCarouselSection: View {
    let title: String
    let items: [PlexAlbum]
    let pageSize: Int
    let onSelect: (PlexAlbum) -> Void
    let onPlayNext: (PlexAlbum) -> Void
    let onAddToQueue: (PlexAlbum) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage) {
                HStack(spacing: 10) {
                    ForEach(Array(currentItems.enumerated()), id: \.offset) { _, album in
                        if let album {
                            Button {
                                onSelect(album)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkImage(url: album.artworkURL, placeholderSystemImage: "music.note")
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))

                                    Text(album.title)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .lineLimit(1)
                                    Text(album.artist)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary.opacity(0.72))
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .interactiveCursor()
                            .contentShape(Rectangle())
                            .frame(width: 100, alignment: .leading)
                            .contextMenu {
                                Button("Play Now") { onSelect(album) }
                                Button("Play Next") { onPlayNext(album) }
                                Button("Add to Queue") { onAddToQueue(album) }
                            }
                        } else {
                            Color.clear
                                .frame(width: 100, height: 136)
                        }
                    }
                }
                .frame(width: MenuBarLayout.contentWidth - 2, alignment: .leading)
            }
            .onChange(of: items.count) { _, _ in
                page = min(page, maxPage)
            }
        }
    }

    private var maxPage: Int {
        guard !items.isEmpty else { return 0 }
        return (items.count - 1) / pageSize
    }

    private var currentItems: [PlexAlbum?] {
        let start = page * pageSize
        guard start < items.count else {
            return Array(repeating: nil, count: pageSize)
        }

        let end = min(start + pageSize, items.count)
        let pageItems = Array(items[start..<end]).map(Optional.some)
        if pageItems.count < pageSize {
            return pageItems + Array(repeating: nil, count: pageSize - pageItems.count)
        }

        return pageItems
    }
}

private struct ArtworkImage: View {
    let url: URL?
    let placeholderSystemImage: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .empty:
                placeholder(isLoading: url != nil)
            case .failure:
                placeholder(isLoading: false)
            @unknown default:
                placeholder(isLoading: false)
            }
        }
    }

    private func placeholder(isLoading: Bool) -> some View {
        AppTheme.artworkPlaceholder
            .overlay {
                Image(systemName: placeholderSystemImage)
                    .foregroundStyle(.secondary.opacity(0.55))
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }
}

private struct PlaylistCarouselSection: View {
    let title: String
    let items: [PlexPlaylist]
    let pageSize: Int
    let onSelect: (PlexPlaylist) -> Void
    let onPlayNext: (PlexPlaylist) -> Void
    let onAddToQueue: (PlexPlaylist) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage) {
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                if let playlist = currentItems[index] {
                                    Button {
                                        onSelect(playlist)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(playlist.title)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .lineLimit(1)
                                            Text("\(playlist.trackCount) tracks")
                                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                                .foregroundStyle(.secondary.opacity(0.74))
                                        }
                                        .padding(8)
                                        .frame(width: 210, alignment: .leading)
                                        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .interactiveCursor()
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("Play Now") { onSelect(playlist) }
                                        Button("Play Next") { onPlayNext(playlist) }
                                        Button("Add to Queue") { onAddToQueue(playlist) }
                                    }
                                } else {
                                    Color.clear
                                        .frame(width: 210, height: 56)
                                }
                            }
                        }
                    }
                }
                .frame(width: MenuBarLayout.contentWidth - 4, alignment: .leading)
            }
            .onChange(of: items.count) { _, _ in
                page = min(page, maxPage)
            }
        }
    }

    private var maxPage: Int {
        guard !items.isEmpty else { return 0 }
        return (items.count - 1) / pageSize
    }

    private var currentItems: [PlexPlaylist?] {
        let start = page * pageSize
        guard start < items.count else {
            return Array(repeating: nil, count: pageSize)
        }

        let end = min(start + pageSize, items.count)
        let pageItems = Array(items[start..<end]).map(Optional.some)
        if pageItems.count < pageSize {
            return pageItems + Array(repeating: nil, count: pageSize - pageItems.count)
        }

        return pageItems
    }
}

private struct StationCarouselSection: View {
    let title: String
    let items: [PlexStation]
    let pageSize: Int
    let onSelect: (PlexStation) -> Void
    let onPlayNext: (PlexStation) -> Void
    let onAddToQueue: (PlexStation) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage) {
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                if let station = currentItems[index] {
                                    Button {
                                        onSelect(station)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "radio")
                                                .foregroundStyle(AppTheme.accent)
                                            Text(station.title)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .lineLimit(2)
                                        }
                                        .padding(8)
                                        .frame(width: 210, height: 56, alignment: .leading)
                                        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .interactiveCursor()
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("Play Now") { onSelect(station) }
                                        Button("Play Next") { onPlayNext(station) }
                                        Button("Add to Queue") { onAddToQueue(station) }
                                    }
                                } else {
                                    Color.clear
                                        .frame(width: 210, height: 56)
                                }
                            }
                        }
                    }
                }
                .frame(width: MenuBarLayout.contentWidth - 4, alignment: .leading)
            }
            .onChange(of: items.count) { _, _ in
                page = min(page, maxPage)
            }
        }
    }

    private var maxPage: Int {
        guard !items.isEmpty else { return 0 }
        return (items.count - 1) / pageSize
    }

    private var currentItems: [PlexStation?] {
        let start = page * pageSize
        guard start < items.count else {
            return Array(repeating: nil, count: pageSize)
        }

        let end = min(start + pageSize, items.count)
        let pageItems = Array(items[start..<end]).map(Optional.some)
        if pageItems.count < pageSize {
            return pageItems + Array(repeating: nil, count: pageSize - pageItems.count)
        }

        return pageItems
    }
}

private struct CarouselContainer<Content: View>: View {
    let title: String
    @Binding var page: Int
    let maxPage: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.accent)

                Spacer()

                if maxPage > 0 {
                    Text("\(page + 1)/\(maxPage + 1)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))

                    Button {
                        page = max(0, page - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .disabled(page == 0)
                    .interactiveCursor(disabled: page == 0)

                    Button {
                        page = min(maxPage, page + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(page == maxPage)
                    .interactiveCursor(disabled: page == maxPage)
                }
            }

            content
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }
}

private struct RelatedAlbumsSection: View {
    let albums: [PlexAlbum]
    let onSelect: (PlexAlbum) -> Void
    let onPlayNext: (PlexAlbum) -> Void
    let onAddToQueue: (PlexAlbum) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related Albums")
                .font(.system(size: 12, weight: .bold, design: .rounded))

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(albums.prefix(3))) { album in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            onSelect(album)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ArtworkImage(url: album.artworkURL, placeholderSystemImage: "music.note")
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))

                                Text(album.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                Text(album.artist)
                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .interactiveCursor()

                        HStack(spacing: 6) {
                            albumQueueButton(icon: "text.line.first.and.arrowtriangle.forward", help: "Play Album Next") {
                                onPlayNext(album)
                            }
                            albumQueueButton(icon: "text.badge.plus", help: "Add Album to Queue") {
                                onAddToQueue(album)
                            }
                        }
                    }
                    .frame(width: 100, alignment: .leading)
                }
            }
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }

    private func albumQueueButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 24)
                .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
        .interactiveCursor()
        .help(help)
    }
}

private struct PlayQueueView: View {
    @ObservedObject var appState: AppState
    @State private var showsPlayedTracks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Play Queue")
                    .font(.system(size: 12, weight: .bold, design: .rounded))

                Spacer()

                if appState.isQueueOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    appState.refreshPlayQueue()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .disabled(!appState.hasEditablePlayQueue || appState.isQueueOperationInProgress)
                .interactiveCursor(disabled: !appState.hasEditablePlayQueue || appState.isQueueOperationInProgress)
                .help("Refresh Play Queue")

                Button {
                    appState.clearUpcomingPlayQueueTracks()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red.opacity(0.9))
                .disabled(!hasUpcomingTracks || appState.isQueueOperationInProgress)
                .interactiveCursor(disabled: !hasUpcomingTracks || appState.isQueueOperationInProgress)
                .help("Clear Upcoming Tracks")
            }

            if !playedTracks.isEmpty {
                Button {
                    showsPlayedTracks.toggle()
                } label: {
                    Label("Played tracks", systemImage: showsPlayedTracks ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .interactiveCursor()
            }

            if !displayedTracks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                        queueRow(track)
                        if index < displayedTracks.count - 1 {
                            Divider()
                                .overlay(AppTheme.settingsDivider)
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
            } else {
                Text("Start playback from an album, playlist, or station to create an editable queue.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.74))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
            }
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }

    private func queueRow(_ track: PlexTrack) -> some View {
        let isCurrent = track.id == appState.currentPlayQueueTrackID
        let isUpcoming = appState.visiblePlayQueue.firstIndex(where: { $0.id == track.id }).map { $0 > currentTrackIndex } ?? false

        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCurrent ? AppTheme.accent : Color.secondary.opacity(0.55))
                .frame(width: 16)

            Button {
                appState.selectPlayQueueTrack(id: track.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(track.trackArtist ?? track.albumArtist ?? track.albumName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(appState.isQueueOperationInProgress)

            if isUpcoming {
                Button {
                    appState.removePlayQueueTrack(id: track.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
                .disabled(appState.isQueueOperationInProgress)
                .help("Remove Track from Play Queue")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isCurrent ? AppTheme.overlaySoft : .clear)
        .draggable(track.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let sourceID = ids.first else { return false }
            appState.movePlayQueueTrack(id: sourceID, before: track.id)
            return true
        }
    }

    private var currentTrackIndex: Int {
        appState.visiblePlayQueue.firstIndex(where: { $0.id == appState.currentPlayQueueTrackID }) ?? -1
    }

    private var playedTracks: [PlexTrack] {
        guard currentTrackIndex > 0 else { return [] }
        return Array(appState.visiblePlayQueue.prefix(currentTrackIndex))
    }

    private var displayedTracks: [PlexTrack] {
        guard currentTrackIndex >= 0, !showsPlayedTracks else {
            return appState.visiblePlayQueue
        }

        return Array(appState.visiblePlayQueue.dropFirst(currentTrackIndex))
    }

    private var hasUpcomingTracks: Bool {
        currentTrackIndex >= 0 && currentTrackIndex < appState.visiblePlayQueue.count - 1
    }
}

private struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            settingsHeader

            VStack(alignment: .leading, spacing: 16) {
                settingsSection("Library") {
                    pickerRow("Server", selection: serverSelectionBinding, items: appState.availableServers.map { ($0.name, Optional($0.id)) })
                        .disabled(appState.availableServers.isEmpty)
                    dividerRow
                    pickerRow("Music Library", selection: librarySelectionBinding, items: appState.availableLibraries.map { ($0.title, Optional($0.id)) })
                        .disabled(appState.availableLibraries.isEmpty)
                }

                settingsSection("Menu Bar Format") {
                    pickerRow("First String", selection: firstFieldBinding, items: MenuBarField.allCases.map { ($0.displayName, $0) })
                    dividerRow
                    pickerRow("Next String", selection: secondFieldBinding, items: MenuBarField.allCases.map { ($0.displayName, $0) })
                }

                settingsSection("Appearance") {
                    pickerRow("Theme", selection: themePreferenceBinding, items: AppThemePreference.allCases.map { ($0.displayName, $0) })
                }

                settingsSection("Visible Sections") {
                    toggleRow("Recently Played Albums", isOn: showRecentlyPlayedBinding)
                    dividerRow
                    toggleRow("Recently Added Albums", isOn: showRecentlyAddedBinding)
                    dividerRow
                    toggleRow("Playlists", isOn: showPlaylistsBinding)
                    dividerRow
                    toggleRow("Stations", isOn: showStationsBinding)
                }

                settingsSection("Playback") {
                    toggleRow("Loudness Leveling", isOn: loudnessLevelingBinding)
                    dividerRow
                    pickerRow("Scrobble Threshold", selection: listenedThresholdBinding, items: listenedThresholdOptions)
                }

                Button {
                    appState.signOut()
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .offset(x: 4)
                .interactiveCursor()
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .offset(x: 4)
                .interactiveCursor()
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private var settingsHeader: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 12, weight: .bold, design: .rounded))

            Spacer()

            Button {
                appState.refreshLibraryContent()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .font(.system(size: 12, weight: .semibold))
            .interactiveCursor(disabled: !appState.isAuthenticated)
            .foregroundStyle(AppTheme.accent)
            .disabled(!appState.isAuthenticated)
            .help("Refresh Library Content")
        }
    }

    private var serverSelectionBinding: Binding<String?> {
        Binding {
            appState.selectedServerID
        } set: { newValue in
            if let newValue {
                appState.selectServer(id: newValue)
            }
        }
    }

    private var librarySelectionBinding: Binding<String?> {
        Binding {
            appState.selectedLibraryID
        } set: { newValue in
            if let newValue {
                appState.selectLibrary(id: newValue)
            }
        }
    }

    private var firstFieldBinding: Binding<MenuBarField> {
        Binding {
            appState.settingsStore.settings.menuBarFormat.firstField
        } set: { newValue in
            appState.settingsStore.settings.menuBarFormat.firstField = newValue
        }
    }

    private var secondFieldBinding: Binding<MenuBarField> {
        Binding {
            appState.settingsStore.settings.menuBarFormat.secondField
        } set: { newValue in
            appState.settingsStore.settings.menuBarFormat.secondField = newValue
        }
    }

    private var showRecentlyPlayedBinding: Binding<Bool> {
        Binding {
            appState.settingsStore.settings.sectionVisibility.showRecentlyPlayedAlbums
        } set: { newValue in
            appState.settingsStore.settings.sectionVisibility.showRecentlyPlayedAlbums = newValue
        }
    }

    private var showRecentlyAddedBinding: Binding<Bool> {
        Binding {
            appState.settingsStore.settings.sectionVisibility.showRecentlyAddedAlbums
        } set: { newValue in
            appState.settingsStore.settings.sectionVisibility.showRecentlyAddedAlbums = newValue
        }
    }

    private var showPlaylistsBinding: Binding<Bool> {
        Binding {
            appState.settingsStore.settings.sectionVisibility.showPlaylists
        } set: { newValue in
            appState.settingsStore.settings.sectionVisibility.showPlaylists = newValue
        }
    }

    private var showStationsBinding: Binding<Bool> {
        Binding {
            appState.settingsStore.settings.sectionVisibility.showStations
        } set: { newValue in
            appState.settingsStore.settings.sectionVisibility.showStations = newValue
        }
    }

    private var loudnessLevelingBinding: Binding<Bool> {
        Binding {
            appState.isLoudnessLevelingEnabled
        } set: { newValue in
            appState.setLoudnessLevelingEnabled(newValue)
        }
    }

    private var listenedThresholdBinding: Binding<Int> {
        Binding {
            appState.listenedThresholdPercentage
        } set: { newValue in
            appState.setListenedThresholdPercentage(newValue)
        }
    }

    private var themePreferenceBinding: Binding<AppThemePreference> {
        Binding {
            appState.themePreference
        } set: { newValue in
            appState.setThemePreference(newValue)
        }
    }

    private var listenedThresholdOptions: [(String, Int)] {
        stride(from: 50, through: 100, by: 5).map { ("\($0)%", $0) }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.settingsFieldFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        }
    }

    private var dividerRow: some View {
        Divider()
            .overlay(AppTheme.settingsDivider)
            .padding(.horizontal, 12)
    }

    private func pickerRow<Value: Hashable>(_ title: String, selection: Binding<Value>, items: [(String, Value)]) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            Picker(title, selection: selection) {
                ForEach(items, id: \.0) { label, value in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(.primary)
            .interactiveCursor(disabled: items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .interactiveCursor()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private extension AppThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
