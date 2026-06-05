import SwiftUI

struct SettingsView: View {
    @ObservedObject var authService: PlexAuthService
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var libraryStore: LibraryStore
    @ObservedObject var updateChecker: UpdateChecker
    let onSelectServer: (String) -> Void
    let onSelectLibrary: (String) -> Void
    let onRefreshServersAndLibraries: () -> Void
    let onSetLoudnessLevelingEnabled: (Bool) -> Void
    let onSetFallbackLoudnessGainDecibels: (Int) -> Void
    let onSetListenedThresholdPercentage: (Int) -> Void
    let onSignOut: () -> Void
    let onPanelPositionChange: () -> Void
    let paddingSpaceWidth: CGFloat = 40
    let maxPickerLabelWidth: CGFloat = 180

    var body: some View {
        VStack(spacing: 12) {
            settingsHeader

            updatesSettingsContent

            VStack(alignment: .leading, spacing: 16) {
                if isLocalSource {
                    localSettingsContent
                } else {
                    serverSettingsContent
                }

                Button {
                    onSignOut()
                } label: {
                    Label(signOutTitle, systemImage: signOutIconName)
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

    @ViewBuilder
    private var localSettingsContent: some View {
        settingsSection("Appearance") {
            pickerRow("Theme", selection: themePreferenceBinding, items: AppThemePreference.allCases.map { ($0.displayName, $0) })
            dividerRow
            pickerRow("Panel Position", selection: panelPositionBinding, items: PanelPositionPreference.allCases.map { ($0.displayName, $0) })
        }

        settingsSection("Playback") {
            toggleRow("Loudness Leveling", isOn: loudnessLevelingBinding)
            dividerRow
            pickerRow("Fallback Gain", selection: fallbackLoudnessGainBinding, items: fallbackLoudnessGainOptions)
        }
    }

    @ViewBuilder
    private var updatesSettingsContent: some View {
        settingsSection("Updates") {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Version")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(updateChecker.currentVersionDisplay)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.78))
                    if let lastUpdateCheckText {
                        Text(lastUpdateCheckText)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.62))
                    }
                }

                Spacer()

                Button {
                    Task {
                        await updateChecker.checkForUpdates()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))

                        Text("Check for Updates")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .disabled(isCheckingForUpdates)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(AppTheme.overlayMedium, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .interactiveCursor(disabled: isCheckingForUpdates)
                .disabled(isCheckingForUpdates)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if shouldShowUpdateDetails {
                dividerRow
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        if isCheckingForUpdates {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.72)
                        }

                        Text(updateStatusText ?? "Checking for updates...")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(updateStatusColor)
                            .padding(.vertical, 1.5)
                    }

                    if let release = downloadableRelease {
                        Button {
                            NSWorkspace.shared.open(release.downloadURL)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .buttonStyle(.plain)
                        .focusable(false)
                        .interactiveCursor(disabled: isCheckingForUpdates)
                        .foregroundStyle(isCheckingForUpdates ? Color.secondary.opacity(0.65) : AppTheme.accent)
                        .disabled(isCheckingForUpdates)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shouldShowUpdateDetails)
        .animation(.easeInOut(duration: 0.18), value: updateDetailsAnimationKey)
    }

    @ViewBuilder
    private var serverSettingsContent: some View {
        if isPlexSource {
            settingsSection("Library") {
                pickerRow("Server", selection: serverSelectionBinding, items: libraryStore.availableServers.map { ($0.name, Optional($0.id)) })
                    .disabled(libraryStore.availableServers.isEmpty)
                dividerRow
                pickerRow("Music Library", selection: librarySelectionBinding, items: libraryStore.availableLibraries.map { ($0.title, Optional($0.id)) })
                    .disabled(libraryStore.availableLibraries.isEmpty)
            }
        }

        settingsSection("Menu Bar Format") {
            pickerRow("First String", selection: firstFieldBinding, items: MenuBarField.allCases.map { ($0.displayName, $0) })
            dividerRow
            pickerRow("Next String", selection: secondFieldBinding, items: MenuBarField.allCases.map { ($0.displayName, $0) })
        }

        settingsSection("Appearance") {
            pickerRow("Theme", selection: themePreferenceBinding, items: AppThemePreference.allCases.map { ($0.displayName, $0) })
            dividerRow
            pickerRow("Panel Position", selection: panelPositionBinding, items: PanelPositionPreference.allCases.map { ($0.displayName, $0) })
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
            pickerRow("Fallback Gain", selection: fallbackLoudnessGainBinding, items: fallbackLoudnessGainOptions)
            dividerRow
            pickerRow("Scrobble Threshold", selection: listenedThresholdBinding, items: listenedThresholdOptions)
        }
    }

    private var settingsHeader: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.accent)

            Spacer()

            if !isLocalSource {
                Button {
                    onRefreshServersAndLibraries()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .font(.system(size: 12, weight: .semibold))
                .interactiveCursor(disabled: !canRefreshLibrary)
                .foregroundStyle(AppTheme.accent)
                .disabled(!canRefreshLibrary)
                .help(isPlexSource ? "Refresh Servers and Libraries" : "Refresh Library")
            }
        }
    }

    private var isPlexSource: Bool {
        settingsStore.settings.mediaSource == .plex
    }

    private var canRefreshLibrary: Bool {
        switch settingsStore.settings.mediaSource {
        case .plex:
            return authService.authToken != nil
        case .navidrome:
            return settingsStore.settings.navidromeConfig.isFilled
        case .local, .unspecified:
            return false
        }
    }

    private var isLocalSource: Bool {
        settingsStore.settings.mediaSource == .local
    }

    private var signOutTitle: String {
        isLocalSource ? "Connect Other Services" : "Log Out"
    }

    private var signOutIconName: String {
        isLocalSource ? "point.3.connected.trianglepath.dotted" : "rectangle.portrait.and.arrow.right"
    }

    private var serverSelectionBinding: Binding<String?> {
        Binding {
            settingsStore.settings.selectedServerID
        } set: { newValue in
            if let newValue {
                onSelectServer(newValue)
            }
        }
    }

    private var librarySelectionBinding: Binding<String?> {
        Binding {
            settingsStore.settings.selectedLibraryID
        } set: { newValue in
            if let newValue {
                onSelectLibrary(newValue)
            }
        }
    }

    private var firstFieldBinding: Binding<MenuBarField> {
        Binding {
            settingsStore.settings.menuBarFormat.firstField
        } set: { newValue in
            settingsStore.settings.menuBarFormat.firstField = newValue
        }
    }

    private var secondFieldBinding: Binding<MenuBarField> {
        Binding {
            settingsStore.settings.menuBarFormat.secondField
        } set: { newValue in
            settingsStore.settings.menuBarFormat.secondField = newValue
        }
    }

    private var showRecentlyPlayedBinding: Binding<Bool> {
        Binding {
            settingsStore.settings.sectionVisibility.showRecentlyPlayedAlbums
        } set: { newValue in
            settingsStore.settings.sectionVisibility.showRecentlyPlayedAlbums = newValue
        }
    }

    private var showRecentlyAddedBinding: Binding<Bool> {
        Binding {
            settingsStore.settings.sectionVisibility.showRecentlyAddedAlbums
        } set: { newValue in
            settingsStore.settings.sectionVisibility.showRecentlyAddedAlbums = newValue
        }
    }

    private var showPlaylistsBinding: Binding<Bool> {
        Binding {
            settingsStore.settings.sectionVisibility.showPlaylists
        } set: { newValue in
            settingsStore.settings.sectionVisibility.showPlaylists = newValue
        }
    }

    private var showStationsBinding: Binding<Bool> {
        Binding {
            settingsStore.settings.sectionVisibility.showStations
        } set: { newValue in
            settingsStore.settings.sectionVisibility.showStations = newValue
        }
    }

    private var loudnessLevelingBinding: Binding<Bool> {
        Binding {
            settingsStore.settings.loudnessLevelingEnabled
        } set: { newValue in
            onSetLoudnessLevelingEnabled(newValue)
        }
    }

    private var listenedThresholdBinding: Binding<Int> {
        Binding {
            settingsStore.settings.listenedThresholdPercentage
        } set: { newValue in
            onSetListenedThresholdPercentage(newValue)
        }
    }

    private var fallbackLoudnessGainBinding: Binding<Int> {
        Binding {
            settingsStore.settings.fallbackLoudnessGainDecibels
        } set: { newValue in
            onSetFallbackLoudnessGainDecibels(newValue)
        }
    }

    private var themePreferenceBinding: Binding<AppThemePreference> {
        Binding {
            settingsStore.settings.themePreference
        } set: { newValue in
            settingsStore.settings.themePreference = newValue
        }
    }

    private var panelPositionBinding: Binding<PanelPositionPreference> {
        Binding {
            settingsStore.settings.panelPosition
        } set: { newValue in
            settingsStore.settings.panelPosition = newValue
            onPanelPositionChange()
        }
    }

    private var listenedThresholdOptions: [(String, Int)] {
        stride(from: 50, through: 100, by: 5).map { ("\($0)%", $0) }
    }

    private var fallbackLoudnessGainOptions: [(String, Int)] {
        stride(from: -2, through: -10, by: -1).map { ("\($0) dB\($0 == settingsStore.settings.fallbackLoudnessGainDecibels ? " (Default)" : "")", $0) }
    }

    private var isCheckingForUpdates: Bool {
        if case .checking = updateChecker.state {
            return true
        }
        return false
    }

    private var downloadableRelease: ReleaseManifest? {
        switch updateChecker.state {
        case let .updateAvailable(release), let .informational(release):
            return release
        case .checking:
            return updateChecker.retainedDownloadableRelease
        case .idle, .upToDate, .failed:
            return nil
        }
    }

    private var updateStatusText: String? {
        switch updateChecker.state {
        case .idle:
            return nil
        case .checking:
            if let release = updateChecker.retainedDownloadableRelease {
                return "Checking for updates. Latest known release is \(release.tag)."
            }
            return "Checking for updates..."
        case let .upToDate(release):
            return "You're up to date with \(release.tag), released \(release.releaseDate)."
        case let .updateAvailable(release):
            return "Version \(release.tag) is available, released \(release.releaseDate)."
        case let .informational(release):
            return "Latest release is \(release.tag), released \(release.releaseDate)."
        case let .failed(message):
            return message
        }
    }

    private var updateStatusColor: Color {
        switch updateChecker.state {
        case .failed:
            return .yellow
        case .updateAvailable, .informational, .idle, .checking, .upToDate:
            return .secondary.opacity(0.78)
        }
    }

    private var shouldShowUpdateDetails: Bool {
        isCheckingForUpdates || updateStatusText != nil || downloadableRelease != nil
    }

    private var updateDetailsAnimationKey: String {
        switch updateChecker.state {
        case .idle:
            return "idle"
        case .checking:
            return "checking-\(downloadableRelease?.tag ?? "none")"
        case let .upToDate(release):
            return "upToDate-\(release.tag)"
        case let .updateAvailable(release):
            return "updateAvailable-\(release.tag)"
        case let .informational(release):
            return "informational-\(release.tag)"
        case let .failed(message):
            return "failed-\(message)"
        }
    }

    private var lastUpdateCheckText: String? {
        guard let lastCheckDate = updateChecker.lastCheckDate else { return nil }
        return "Last checked \(lastCheckDate.formatted(date: .abbreviated, time: .shortened))"
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
        let maxLabelWidth = items.map { label, _ in
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let attributes = [NSAttributedString.Key.font: font]
            let size = (label as NSString).size(withAttributes: attributes)
            return size.width
        }.max() ?? 80

        return HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            Menu {
                ForEach(items, id: \.0) { label, value in
                    Button {
                        selection.wrappedValue = value
                    } label: {
                        HStack {
                            Text(label)
                            Spacer()
                            if selection.wrappedValue == value {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(labelText(for: selection.wrappedValue, items: items))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: maxLabelWidth + paddingSpaceWidth, alignment: .trailing)
                .background(AppTheme.settingsFieldFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: maxPickerLabelWidth, alignment: .trailing)
            .interactiveCursor(disabled: items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func labelText<Value: Hashable>(for selection: Value, items: [(String, Value)]) -> String {
        items.first(where: { _, value in value == selection })?.0 ?? "Select..."
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(CompactAccentToggleStyle())
        }
        .interactiveCursor()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct CompactAccentToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(configuration.isOn ? AppTheme.accent : Color.secondary.opacity(0.28))
                .frame(width: 34, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
    }
}

extension AppThemePreference {
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
