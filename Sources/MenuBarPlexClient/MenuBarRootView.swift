import AppKit
import SwiftUI

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
    @ObservedObject var appState: AppState
    let onClose: () -> Void
    let onTabChange: (Bool) -> Void
    @State private var selectedTab: ContentTab = .home

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
                            .padding(4)
                            .contentShape(Rectangle())
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


