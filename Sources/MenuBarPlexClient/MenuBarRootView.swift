import SwiftUI

private enum MenuBarLayout {
    static let contentWidth: CGFloat = 432
    static let popupWidth: CGFloat = 460
    static let minPopupHeight: CGFloat = 400
}

struct MenuBarRootView: View {
    @ObservedObject var appState: AppState
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                topBar

                if appState.isAuthenticated {
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

                    if showingSettings {
                        SettingsView(appState: appState)
                            .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
                            .background(AppTheme.panelFillSoft, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    } else {
                        let visibility = appState.settingsStore.settings.sectionVisibility

                        if visibility.showRecentlyPlayedAlbums && !appState.recentlyPlayedAlbums.isEmpty {
                            AlbumCarouselSection(
                                title: "Recently Played",
                                items: appState.recentlyPlayedAlbums,
                                pageSize: 4,
                                onSelect: appState.playAlbum
                            )
                        }

                        if visibility.showRecentlyAddedAlbums && !appState.recentlyAddedAlbums.isEmpty {
                            AlbumCarouselSection(
                                title: "Recently Added",
                                items: appState.recentlyAddedAlbums,
                                pageSize: 4,
                                onSelect: appState.playAlbum
                            )
                        }

                        if visibility.showPlaylists && !appState.playlists.isEmpty {
                            PlaylistCarouselSection(
                                title: "Playlists",
                                items: appState.playlists,
                                pageSize: 8,
                                onSelect: appState.playPlaylist
                            )
                        }

                        if !appState.isLoadingLibrary,
                           appState.recentlyPlayedAlbums.isEmpty,
                           appState.recentlyAddedAlbums.isEmpty,
                           appState.playlists.isEmpty {
                            EmptyLibraryCard()
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
            .padding(14)
            .frame(width: MenuBarLayout.contentWidth, alignment: .top)
            .frame(maxWidth: .infinity, minHeight: MenuBarLayout.minPopupHeight, alignment: .top)
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
        .foregroundStyle(.white)
        .onChange(of: appState.shouldOpenSettingsForLibraryError) { _, shouldOpenSettings in
            if shouldOpenSettings {
                showingSettings = true
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text(showingSettings ? "Settings" : "Plex Music")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            Spacer()

            authButton

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark.circle" : "gearshape")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .interactiveCursor()
            .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
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

                if appState.isLoadingLibrary, appState.hasExistingContent {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing...")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                }
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
                        .foregroundStyle(.white.opacity(0.68))
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
            HStack(spacing: 10) {
                Button {
                    appState.refreshLibraryContent()
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .interactiveCursor()

                Button {
                    appState.signOut()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .interactiveCursor()
            }
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
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
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
                .foregroundStyle(.white.opacity(0.78))

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
                        .foregroundStyle(.white.opacity(0.75))

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
            .foregroundStyle(.black)
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
            HStack(spacing: 12) {
                AsyncImage(url: metadata.artworkURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Color.white.opacity(0.12)
                            .overlay(Image(systemName: "music.note.list"))
                    }
                }
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata.trackName)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(metadata.resolvedTrackArtist)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                    Text(metadata.albumName)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 20) {
                transportButton(icon: "backward.fill", action: onPrevious)
                transportButton(icon: playbackState.systemImageName, action: onPlayPause)
                transportButton(icon: "forward.fill", action: onNext)
                transportButton(icon: "shuffle", isActive: isShuffleEnabled, action: onToggleShuffle)
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isSeeking ? sliderValue : playbackProgress },
                        set: { newValue in
                            isSeeking = true
                            sliderValue = newValue
                        }
                    ),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if !editing {
                            onSeek(sliderValue)
                        }
                    }
                )

                HStack {
                    Text(formattedTime(playbackPosition))
                    Spacer()
                    Text(formattedTime(playbackDuration))
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
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

    private func transportButton(icon: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background((isActive ? AppTheme.accentActiveBackground : AppTheme.transportFill), in: Circle())
        }
        .buttonStyle(.plain)
        .interactiveCursor()
        .foregroundStyle(isActive ? AppTheme.accent : .white)
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
                                    AsyncImage(url: album.artworkURL) { phase in
                                        switch phase {
                                        case let .success(image):
                                            image.resizable().scaledToFill()
                                        default:
                                            Color.white.opacity(0.12)
                                        }
                                    }
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))

                                    Text(album.title)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .lineLimit(1)
                                    Text(album.artist)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .interactiveCursor()
                            .contentShape(Rectangle())
                            .frame(width: 100, alignment: .leading)
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

private struct PlaylistCarouselSection: View {
    let title: String
    let items: [PlexPlaylist]
    let pageSize: Int
    let onSelect: (PlexPlaylist) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage) {
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { column in
                                let index = row * 4 + column
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
                                                .foregroundStyle(.white.opacity(0.74))
                                        }
                                        .padding(8)
                                        .frame(width: 101, alignment: .leading)
                                        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .interactiveCursor()
                                    .contentShape(Rectangle())
                                } else {
                                    Color.clear
                                        .frame(width: 101, height: 56)
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
                        .foregroundStyle(.white.opacity(0.68))

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

                settingsSection("Visible Sections") {
                    toggleRow("Recently Played Albums", isOn: showRecentlyPlayedBinding)
                    dividerRow
                    toggleRow("Recently Added Albums", isOn: showRecentlyAddedBinding)
                    dividerRow
                    toggleRow("Playlists", isOn: showPlaylistsBinding)
                }

                settingsSection("Playback") {
                    toggleRow("Loudness Leveling", isOn: loudnessLevelingBinding)
                }
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

            Button("Refresh") {
                appState.refreshLibraryContent()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .interactiveCursor(disabled: !appState.isAuthenticated)
            .foregroundStyle(AppTheme.accent)
            .disabled(!appState.isAuthenticated)
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

    private var loudnessLevelingBinding: Binding<Bool> {
        Binding {
            appState.isLoudnessLevelingEnabled
        } set: { newValue in
            appState.setLoudnessLevelingEnabled(newValue)
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

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
                .foregroundStyle(.white)

            Spacer()

            Picker(title, selection: selection) {
                ForEach(items, id: \.0) { label, value in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(.white)
            .colorScheme(.dark)
            .interactiveCursor(disabled: items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)

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
