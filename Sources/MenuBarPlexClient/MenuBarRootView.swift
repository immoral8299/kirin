import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PanelState: ObservableObject {
    @Published var openCount = 0
}

enum MenuBarLayout {
    static let contentWidth: CGFloat = 436
    static let popupWidth: CGFloat = 460
    static let minPopupHeight: CGFloat = 400
    static let carouselPageSize = 4
}

private enum ContentTab {
    case home
    case queue
    case search
    case settings
}

struct MenuBarRootView: View {
    let appState: AppState
    let onClose: () -> Void
    let onPinChange: (Bool) -> Void
    let onPanelPositionChange: () -> Void
    let onExternalFileDialogChange: (Bool) -> Void
    @ObservedObject var panelState: PanelState
    @ObservedObject private var authService: PlexAuthService
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var updateChecker: UpdateChecker
    @State private var selectedTab: ContentTab

    init(
        appState: AppState,
        panelState: PanelState,
        onClose: @escaping () -> Void,
        onPinChange: @escaping (Bool) -> Void,
        onPanelPositionChange: @escaping () -> Void,
        onExternalFileDialogChange: @escaping (Bool) -> Void
    ) {
        self.appState = appState
        self.panelState = panelState
        self.onClose = onClose
        self.onPinChange = onPinChange
        self.onPanelPositionChange = onPanelPositionChange
        self.onExternalFileDialogChange = onExternalFileDialogChange
        _authService = ObservedObject(wrappedValue: appState.authService)
        _settingsStore = ObservedObject(wrappedValue: appState.settingsStore)
        _updateChecker = ObservedObject(wrappedValue: appState.updateChecker)
        _selectedTab = State(initialValue: appState.isLocalMode ? .queue : .home)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 14) {
                    scrollableContent
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
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
        .preferredColorScheme(settingsStore.settings.themePreference.colorScheme)
        .id(panelState.openCount)
    }

    @ViewBuilder
    private var scrollableContent: some View {
        if appState.isConfigured {
            AuthenticatedContent(
                appState: appState,
                selectedTab: selectedTab,
                onPanelPositionChange: onPanelPositionChange,
                onExternalFileDialogChange: onExternalFileDialogChange
            )
        } else {
            WelcomeCard(
                mediaSource: $settingsStore.settings.mediaSource,
                navidromeConfig: settingsStore.settings.navidromeConfig,
                authState: authService.status.state,
                onBeginPlexLogin: appState.beginPlexLogin,
                onOpenBrowser: authService.reopenBrowser,
                onConfigureNavidrome: appState.configureNavidrome,
                onVerifyNavidrome: appState.verifyNavidromeConnection,
                onPinChange: onPinChange,
                onConfigureLocalFiles: appState.configureLocalFiles
            )
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 12, height: 12)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .interactiveCursor()

            HStack(alignment: .bottom, spacing: 4) {
                Text("Kirin")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(tabTitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            Spacer()

            authButton

            if appState.isConfigured {
                if appState.isLocalMode {
                    tabButton(.queue, icon: "list.bullet", tooltip: "Play Queue")
                    tabButton(.settings, icon: "gearshape", tooltip: "Settings")
                } else {
                    tabButton(.home, icon: "house", tooltip: "Home")
                    tabButton(.queue, icon: "list.bullet", tooltip: "Play Queue")
                    tabButton(.search, icon: "magnifyingglass", tooltip: "Search")
                    tabButton(.settings, icon: "gearshape", tooltip: "Settings")
                }
            }
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }

    private var tabTitle: String {
        switch selectedTab {
        case .home:
            return ""
        case .queue:
            return "/ Queue"
        case .search:
            return "/ Search"
        case .settings:
            return "/ Settings"
        }
    }

    private func tabButton(_ tab: ContentTab, icon: String, tooltip: String) -> some View {
        Button {
            selectedTab = tab
            onPinChange(false)
        } label: {
            Image(systemName: icon)
                .frame(width: 16, height: 16)
                .padding(6)
                .contentShape(Rectangle())
                .background(selectedTab == tab ? AppTheme.overlayStrong : .clear, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if tab == .settings && updateChecker.hasDownloadableRelease {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                            .offset(x: -5, y: 5)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .interactiveCursor()
        .foregroundStyle(selectedTab == tab ? AppTheme.accent : Color.secondary.opacity(0.8))
        .help(tooltip)
    }

    @ViewBuilder
    private var authButton: some View {
        switch authService.status.state {
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

private struct AuthenticatedContent: View {
    let appState: AppState
    let selectedTab: ContentTab
    let onPanelPositionChange: () -> Void
    let onExternalFileDialogChange: (Bool) -> Void
    @ObservedObject private var libraryStore: LibraryStore

    init(
        appState: AppState,
        selectedTab: ContentTab,
        onPanelPositionChange: @escaping () -> Void,
        onExternalFileDialogChange: @escaping (Bool) -> Void
    ) {
        self.appState = appState
        self.selectedTab = selectedTab
        self.onPanelPositionChange = onPanelPositionChange
        self.onExternalFileDialogChange = onExternalFileDialogChange
        _libraryStore = ObservedObject(wrappedValue: appState.libraryStore)
    }

    var body: some View {
        if libraryStore.shouldPromptForServerSelection {
            ChooseServerCard(
                authService: appState.authService,
                libraryStore: libraryStore,
                onSelectServer: appState.selectServer
            )
        } else if appState.isLocalMode {
            PlaybackSection(appState: appState)

            switch selectedTab {
            case .settings:
                SettingsView(
                    authService: appState.authService,
                    settingsStore: appState.settingsStore,
                    libraryStore: libraryStore,
                    updateChecker: appState.updateChecker,
                    onSelectServer: appState.selectServer,
                    onSelectLibrary: appState.selectLibrary,
                    onRefreshServersAndLibraries: appState.refreshServersAndLibraries,
                    onSetLoudnessLevelingEnabled: appState.setLoudnessLevelingEnabled,
                    onSetFallbackLoudnessGainDecibels: appState.setFallbackLoudnessGainDecibels,
                    onSetListenedThresholdPercentage: appState.setListenedThresholdPercentage,
                    onSignOut: appState.signOut,
                    onPanelPositionChange: onPanelPositionChange
                )
                .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
                .background(AppTheme.panelFillSoft, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            case .queue:
                QueueContent(appState: appState, onExternalFileDialogChange: onExternalFileDialogChange)
            default:
                QueueContent(appState: appState, onExternalFileDialogChange: onExternalFileDialogChange)
            }
        } else {
            activeLibraryBanner
            connectionBanner
            PlaybackSection(appState: appState)

            switch selectedTab {
            case .settings:
                SettingsView(
                    authService: appState.authService,
                    settingsStore: appState.settingsStore,
                    libraryStore: libraryStore,
                    updateChecker: appState.updateChecker,
                    onSelectServer: appState.selectServer,
                    onSelectLibrary: appState.selectLibrary,
                    onRefreshServersAndLibraries: appState.refreshServersAndLibraries,
                    onSetLoudnessLevelingEnabled: appState.setLoudnessLevelingEnabled,
                    onSetFallbackLoudnessGainDecibels: appState.setFallbackLoudnessGainDecibels,
                    onSetListenedThresholdPercentage: appState.setListenedThresholdPercentage,
                    onSignOut: appState.signOut,
                    onPanelPositionChange: onPanelPositionChange
                )
                .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
                .background(AppTheme.panelFillSoft, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            case .queue:
                QueueContent(appState: appState, onExternalFileDialogChange: onExternalFileDialogChange)
            case .search:
                SearchView(appState: appState)
            case .home:
                HomeContent(appState: appState)
            }
        }
    }

    @ViewBuilder
    private var activeLibraryBanner: some View {
        if let serverName = libraryStore.selectedServerName,
           let libraryTitle = libraryStore.selectedLibraryTitle {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .foregroundStyle(AppTheme.accent)
                Text("\(serverName) / \(libraryTitle)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if libraryStore.isLoadingLibrary, libraryStore.hasExistingContent {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing...")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))
                }
                Button(action: appState.refreshCurrentLibraryContent) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.green)
                        .padding(4)
                        .contentShape(Rectangle())
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
    private func recoveryButton(for action: LibraryLoadError.RecoveryAction) -> some View {
        switch action {
        case .retry:
            Button(action: appState.refreshCurrentLibraryContent) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .interactiveCursor()
        case .serverSelection:
            Button(action: appState.refreshServersAndLibraries) {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive")
                    Text("Select Server")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .interactiveCursor()
        case .reauthenticate:
            Button(action: appState.beginPlexLogin) {
                HStack(spacing: 4) {
                    Image(systemName: "person.circle")
                    Text("Re-authenticate")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .interactiveCursor()
        case .dismiss:
            Button(action: appState.dismissLibraryLoadError) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text("Dismiss")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .interactiveCursor()
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if libraryStore.isLoadingLibrary, !libraryStore.hasExistingContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading library...")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                if let loadingTargetDescription = libraryStore.loadingTargetDescription {
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
        } else if let error = libraryStore.libraryLoadError, shouldShowConnectionError(error) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error.message)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(2)
                    Spacer()
                    Button(action: appState.dismissLibraryLoadError) {
                        Image(systemName: "xmark")
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .interactiveCursor()
                    .foregroundStyle(.secondary.opacity(0.72))
                }
                if !error.recoveryActions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(error.recoveryActions, id: \.self) { action in
                            recoveryButton(for: action)
                        }
                    }
                }
            }
            .padding(8)
            .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
            .background(AppTheme.overlayStrong, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
    }

    private func shouldShowConnectionError(_ error: LibraryLoadError) -> Bool {
        if libraryStore.hasExistingContent,
           error.recoveryActions.contains(.serverSelection) {
            return false
        }

        return true
    }
}

private struct PlaybackSection: View {
    let appState: AppState
    @ObservedObject private var playbackEngine: PlaybackEngine
    @ObservedObject private var queueManager: QueueManager

    init(appState: AppState) {
        self.appState = appState
        _playbackEngine = ObservedObject(wrappedValue: appState.playbackEngine)
        _queueManager = ObservedObject(wrappedValue: appState.queueManager)
    }

    var body: some View {
        NowPlayingCard(
            metadata: playbackEngine.nowPlaying,
            playbackState: playbackEngine.playbackState,
            playbackProgress: playbackEngine.playbackProgress,
            playbackPosition: playbackEngine.playbackPosition,
            playbackDuration: playbackEngine.playbackDuration,
            canSeek: playbackEngine.canSeek,
            isShuffleEnabled: queueManager.isShuffleEnabled,
            canGoToPreviousTrack: queueManager.canGoToPreviousTrack,
            canGoToNextTrack: queueManager.canGoToNextTrack,
            canShuffle: queueManager.canShuffle,
            onPlayPause: appState.togglePlayback,
            onNext: appState.nextTrack,
            onPrevious: appState.previousTrack,
            onSeek: appState.seekToProgress,
            onToggleShuffle: appState.toggleShuffle
        )
        .equatable()
    }
}

private struct HomeContent: View {
    let appState: AppState
    @ObservedObject private var libraryStore: LibraryStore
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var queueManager: QueueManager

    init(appState: AppState) {
        self.appState = appState
        _libraryStore = ObservedObject(wrappedValue: appState.libraryStore)
        _settingsStore = ObservedObject(wrappedValue: appState.settingsStore)
        _queueManager = ObservedObject(wrappedValue: appState.queueManager)
    }

    var body: some View {
        let visibility = settingsStore.settings.sectionVisibility

        VStack(spacing: 14) {
            if visibility.showRecentlyPlayedAlbums && !libraryStore.recentlyPlayedAlbums.isEmpty {
                AlbumCarouselSection(title: "Recently Played", items: libraryStore.recentlyPlayedAlbums, pageSize: MenuBarLayout.carouselPageSize, sectionID: "recently-played", pendingPlaybackID: queueManager.pendingPlaybackID, pendingPlaybackSource: queueManager.pendingPlaybackSource, onSelect: { appState.playAlbum($0) }, onPlayNext: { appState.enqueueAlbum($0, playNext: true) }, onAddToQueue: { appState.enqueueAlbum($0, playNext: false) })
                    .transition(.opacity)
            }
            if visibility.showRecentlyAddedAlbums && !libraryStore.recentlyAddedAlbums.isEmpty {
                AlbumCarouselSection(title: "Recently Added", items: libraryStore.recentlyAddedAlbums, pageSize: MenuBarLayout.carouselPageSize, sectionID: "recently-added", pendingPlaybackID: queueManager.pendingPlaybackID, pendingPlaybackSource: queueManager.pendingPlaybackSource, onSelect: { appState.playAlbum($0) }, onPlayNext: { appState.enqueueAlbum($0, playNext: true) }, onAddToQueue: { appState.enqueueAlbum($0, playNext: false) })
                    .transition(.opacity)
            }
            if visibility.showPlaylists && !libraryStore.playlists.isEmpty {
                PlaylistCarouselSection(title: "Playlists", items: libraryStore.playlists, pageSize: MenuBarLayout.carouselPageSize, pendingPlaybackID: queueManager.pendingPlaybackID, onSelect: appState.playPlaylist, onPlayNext: { appState.enqueuePlaylist($0, playNext: true) }, onAddToQueue: { appState.enqueuePlaylist($0, playNext: false) })
                    .transition(.opacity)
            }
            if visibility.showStations && !libraryStore.stations.isEmpty {
                StationCarouselSection(title: "Stations", items: libraryStore.stations, pageSize: MenuBarLayout.carouselPageSize, pendingPlaybackID: queueManager.pendingPlaybackID, onSelect: appState.playStation, onPlayNext: { appState.enqueueStation($0, playNext: true) }, onAddToQueue: { appState.enqueueStation($0, playNext: false) })
                    .transition(.opacity)
            }
            if !libraryStore.isLoadingLibrary,
               libraryStore.recentlyPlayedAlbums.isEmpty,
               libraryStore.recentlyAddedAlbums.isEmpty,
               libraryStore.playlists.isEmpty,
               libraryStore.stations.isEmpty {
                EmptyLibraryCard()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: libraryStore.recentlyPlayedAlbums.count + libraryStore.recentlyAddedAlbums.count + libraryStore.playlists.count + libraryStore.stations.count)
    }
}

private struct QueueContent: View {
    let appState: AppState
    let onExternalFileDialogChange: (Bool) -> Void
    @ObservedObject private var libraryStore: LibraryStore
    @ObservedObject private var queueManager: QueueManager
    @State private var pendingImportTracks: [MediaTrack] = []
    @State private var pendingUnsupportedCount = 0
    @State private var isImportDestinationPresented = false
    @State private var isDropTargeted = false
    @State private var importFeedback: String?

    init(appState: AppState, onExternalFileDialogChange: @escaping (Bool) -> Void) {
        self.appState = appState
        self.onExternalFileDialogChange = onExternalFileDialogChange
        _libraryStore = ObservedObject(wrappedValue: appState.libraryStore)
        _queueManager = ObservedObject(wrappedValue: appState.queueManager)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 14) {
                if !libraryStore.queueStationRecommendations.isEmpty {
                    QueueStationRecommendationsSection(
                        recommendations: libraryStore.queueStationRecommendations,
                        pendingPlaybackID: queueManager.pendingPlaybackID,
                        onSelect: appState.playStationRecommendation,
                        onAddToQueue: { appState.enqueueStationRecommendation($0, playNext: false) }
                    )
                    .transition(.opacity)
                }
                if !libraryStore.relatedAlbums.isEmpty {
                    RelatedAlbumsSection(
                        albums: libraryStore.relatedAlbums,
                        pendingPlaybackID: queueManager.pendingPlaybackID,
                        pendingPlaybackSource: queueManager.pendingPlaybackSource,
                        onSelect: { appState.playAlbum($0) },
                        onPlayNext: { appState.enqueueAlbum($0, playNext: true) },
                        onAddToQueue: { appState.enqueueAlbum($0, playNext: false) }
                    )
                    .transition(.opacity)
                }
                PlayQueueView(
                    queueManager: appState.queueManager,
                    onSelectTrack: appState.selectPlayQueueTrack,
                    onRemoveTrack: appState.removePlayQueueTrack,
                    onMoveTrack: appState.movePlayQueueTrack,
                    onToggleStationContinuation: appState.toggleStationContinuation,
                    onClearUpcomingTracks: appState.clearUpcomingPlayQueueTracks,
                    isLocalMode: appState.isLocalMode,
                    onImportLocalFiles: chooseLocalFiles
                )
            }
            .opacity(isImportDestinationPresented ? 0 : 1)
            .allowsHitTesting(!isImportDestinationPresented)

            if isImportDestinationPresented {
                importDestinationOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
        }
        .padding(.top, 5.5)
        .overlay {
            if appState.isLocalMode && isDropTargeted {
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            }
        }
        .overlay(alignment: .bottom) {
            if let importFeedback {
                Text(importFeedback)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AppTheme.overlayStrong, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            guard appState.isLocalMode else { return false }
            Task {
                await importDroppedFiles(from: providers)
            }
            return true
        }
        .animation(.easeInOut(duration: 0.25), value: libraryStore.queueStationRecommendations.count + libraryStore.relatedAlbums.count)
    }

    private var importDestinationOverlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text("Add Local Music")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    dismissImportActions()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary.opacity(0.78))
                .interactiveCursor()
                .help("Cancel")
            }

            Text(importDestinationMessage)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.78))

            HStack(spacing: 8) {
                importActionButton("Play", icon: "play.fill") {
                    appState.playLocalTracks(pendingImportTracks)
                    clearPendingImport()
                }

                importActionButton("Add Next", icon: "text.line.first.and.arrowtriangle.forward") {
                    appState.addLocalTracksNext(pendingImportTracks)
                    clearPendingImport()
                }
                .disabled(queueManager.currentPlayQueueTrackID == nil)
                .opacity(queueManager.currentPlayQueueTrackID == nil ? 0.45 : 1)

                importActionButton("Add to Queue", icon: "text.append") {
                    appState.appendLocalTracks(pendingImportTracks)
                    clearPendingImport()
                }
            }
        }
        .padding(14)
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .stroke(AppTheme.overlayStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
    }

    private func importActionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(AppTheme.accent)
        .interactiveCursor()
    }

    private var importDestinationMessage: String {
        let trackCount = pendingImportTracks.count
        let trackWord = trackCount == 1 ? "track" : "tracks"
        if pendingUnsupportedCount > 0 {
            let fileWord = pendingUnsupportedCount == 1 ? "file" : "files"
            return "\(trackCount) \(trackWord) ready. \(pendingUnsupportedCount) unsupported \(fileWord) skipped."
        }
        return "\(trackCount) \(trackWord) ready."
    }

    private func chooseLocalFiles() {
        Task {
            onExternalFileDialogChange(true)
            let result = await appState.selectLocalFilesForImport()
            onExternalFileDialogChange(false)
            presentImportActions(for: result)
        }
    }

    private func importDroppedFiles(from providers: [NSItemProvider]) async {
        let urls = await fileURLs(from: providers)
        guard !urls.isEmpty else {
            showImportFeedback("No files found in drop.")
            return
        }
        presentImportActions(for: await appState.buildLocalTracks(from: urls))
    }

    private func presentImportActions(for result: LocalFileImportResult) {
        guard !result.tracks.isEmpty else {
            if result.unsupportedCount > 0 {
                showImportFeedback("Unsupported audio files skipped.")
            }
            return
        }

        guard queueManager.currentPlayQueueTrackID != nil else {
            appState.playLocalTracks(result.tracks)
            if result.unsupportedCount > 0 {
                showImportFeedback("Unsupported audio files skipped.")
            }
            return
        }

        pendingImportTracks = result.tracks
        pendingUnsupportedCount = result.unsupportedCount
        isImportDestinationPresented = true
    }

    private func clearPendingImport() {
        pendingImportTracks = []
        pendingUnsupportedCount = 0
        isImportDestinationPresented = false
    }

    private func dismissImportActions() {
        clearPendingImport()
    }

    private func showImportFeedback(_ message: String) {
        importFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard importFeedback == message else { return }
            importFeedback = nil
        }
    }

    private func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await fileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    url = URL(string: string)
                } else if let string = item as? String {
                    url = URL(string: string)
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }
}
