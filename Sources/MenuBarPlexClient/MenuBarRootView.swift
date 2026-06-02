import AppKit
import Combine
import SwiftUI

@MainActor
final class PanelState: ObservableObject {
    @Published var openCount = 0
}

enum MenuBarLayout {
    static let contentWidth: CGFloat = 436
    static let popupWidth: CGFloat = 460
    static let minPopupHeight: CGFloat = 400
}

private enum ContentTab {
    case home
    case queue
    case settings
}

struct MenuBarRootView: View {
    let appState: AppState
    let onClose: () -> Void
    let onTabChange: (Bool) -> Void
    @ObservedObject var panelState: PanelState
    @ObservedObject private var authService: PlexAuthService
    @ObservedObject private var settingsStore: SettingsStore
    @State private var selectedTab: ContentTab = .home

    init(appState: AppState, panelState: PanelState, onClose: @escaping () -> Void, onTabChange: @escaping (Bool) -> Void) {
        self.appState = appState
        self.panelState = panelState
        self.onClose = onClose
        self.onTabChange = onTabChange
        _authService = ObservedObject(wrappedValue: appState.authService)
        _settingsStore = ObservedObject(wrappedValue: appState.settingsStore)
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
        if authService.authToken != nil {
            AuthenticatedContent(appState: appState, selectedTab: selectedTab)
        } else {
            LoginPromptCard(
                authState: authService.status.state,
                onConnect: appState.beginPlexLogin,
                onOpenBrowser: authService.reopenBrowser
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

            Text(tabTitle)
                .font(.system(size: 14, weight: .bold, design: .rounded))

            Spacer()

            authButton

            if authService.authToken != nil {
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
                .frame(width: 16, height: 16)
                .padding(6)
                .contentShape(Rectangle())
                .background(selectedTab == tab ? AppTheme.overlayStrong : .clear, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
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
    @ObservedObject private var libraryStore: LibraryStore

    init(appState: AppState, selectedTab: ContentTab) {
        self.appState = appState
        self.selectedTab = selectedTab
        _libraryStore = ObservedObject(wrappedValue: appState.libraryStore)
    }

    var body: some View {
        if libraryStore.shouldPromptForServerSelection {
            ChooseServerCard(
                authService: appState.authService,
                libraryStore: libraryStore,
                onSelectServer: appState.selectServer
            )
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
                    onSelectServer: appState.selectServer,
                    onSelectLibrary: appState.selectLibrary,
                    onRefreshServersAndLibraries: appState.refreshServersAndLibraries,
                    onSetLoudnessLevelingEnabled: appState.setLoudnessLevelingEnabled,
                    onSetListenedThresholdPercentage: appState.setListenedThresholdPercentage,
                    onSignOut: appState.signOut
                )
                .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
                .background(AppTheme.panelFillSoft, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            case .queue:
                QueueContent(appState: appState)
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
    private var connectionBanner: some View {
        if libraryStore.isLoadingLibrary, !libraryStore.hasExistingContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Plex library...")
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
        } else if let error = libraryStore.libraryLoadError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
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
            .padding(8)
            .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
            .background(AppTheme.overlayStrong, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
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
            isShuffleEnabled: queueManager.isShuffleEnabled,
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

        if visibility.showRecentlyPlayedAlbums && !libraryStore.recentlyPlayedAlbums.isEmpty {
            AlbumCarouselSection(title: "Recently Played", items: libraryStore.recentlyPlayedAlbums, pageSize: 4, sectionID: "recently-played", pendingPlaybackID: queueManager.pendingPlaybackID, pendingPlaybackSource: queueManager.pendingPlaybackSource, onSelect: { appState.playAlbum($0, source: "recently-played") }, onPlayNext: { appState.enqueueAlbum($0, playNext: true) }, onAddToQueue: { appState.enqueueAlbum($0, playNext: false) })
        }
        if visibility.showRecentlyAddedAlbums && !libraryStore.recentlyAddedAlbums.isEmpty {
            AlbumCarouselSection(title: "Recently Added", items: libraryStore.recentlyAddedAlbums, pageSize: 4, sectionID: "recently-added", pendingPlaybackID: queueManager.pendingPlaybackID, pendingPlaybackSource: queueManager.pendingPlaybackSource, onSelect: { appState.playAlbum($0, source: "recently-added") }, onPlayNext: { appState.enqueueAlbum($0, playNext: true) }, onAddToQueue: { appState.enqueueAlbum($0, playNext: false) })
        }
        if visibility.showPlaylists && !libraryStore.playlists.isEmpty {
            PlaylistCarouselSection(title: "Playlists", items: libraryStore.playlists, pageSize: 4, pendingPlaybackID: queueManager.pendingPlaybackID, onSelect: appState.playPlaylist, onPlayNext: { appState.enqueuePlaylist($0, playNext: true) }, onAddToQueue: { appState.enqueuePlaylist($0, playNext: false) })
        }
        if visibility.showStations && !libraryStore.stations.isEmpty {
            StationCarouselSection(title: "Stations", items: libraryStore.stations, pageSize: 4, pendingPlaybackID: queueManager.pendingPlaybackID, onSelect: appState.playStation, onPlayNext: { appState.enqueueStation($0, playNext: true) }, onAddToQueue: { appState.enqueueStation($0, playNext: false) })
        }
        if !libraryStore.isLoadingLibrary,
           libraryStore.recentlyPlayedAlbums.isEmpty,
           libraryStore.recentlyAddedAlbums.isEmpty,
           libraryStore.playlists.isEmpty,
           libraryStore.stations.isEmpty {
            EmptyLibraryCard()
        }
    }
}

private struct QueueContent: View {
    let appState: AppState
    @ObservedObject private var libraryStore: LibraryStore
    @ObservedObject private var queueManager: QueueManager

    init(appState: AppState) {
        self.appState = appState
        _libraryStore = ObservedObject(wrappedValue: appState.libraryStore)
        _queueManager = ObservedObject(wrappedValue: appState.queueManager)
    }

    var body: some View {
        if !libraryStore.queueStationRecommendations.isEmpty {
            QueueStationRecommendationsSection(
                recommendations: libraryStore.queueStationRecommendations,
                pendingPlaybackID: queueManager.pendingPlaybackID,
                onSelect: appState.playStationRecommendation,
                onAddToQueue: appState.enqueueStationRecommendation
            )
        }
        if !libraryStore.relatedAlbums.isEmpty {
            RelatedAlbumsSection(
                albums: libraryStore.relatedAlbums,
                pendingPlaybackID: queueManager.pendingPlaybackID,
                pendingPlaybackSource: queueManager.pendingPlaybackSource,
                onSelect: { appState.playAlbum($0, source: "related-albums") },
                onPlayNext: { appState.enqueueAlbum($0, playNext: true) },
                onAddToQueue: { appState.enqueueAlbum($0, playNext: false) }
            )
        }
        PlayQueueView(
            queueManager: appState.queueManager,
            onRefresh: appState.refreshPlayQueue,
            onSelectTrack: appState.selectPlayQueueTrack,
            onRemoveTrack: appState.removePlayQueueTrack,
            onMoveTrack: appState.movePlayQueueTrack,
            onClearUpcomingTracks: appState.clearUpcomingPlayQueueTracks
        )
    }
}
