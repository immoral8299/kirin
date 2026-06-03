import SwiftUI

struct SettingsView: View {
    @ObservedObject var authService: PlexAuthService
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var libraryStore: LibraryStore
    let onSelectServer: (String) -> Void
    let onSelectLibrary: (String) -> Void
    let onRefreshServersAndLibraries: () -> Void
    let onSetLoudnessLevelingEnabled: (Bool) -> Void
    let onSetListenedThresholdPercentage: (Int) -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            settingsHeader

            VStack(alignment: .leading, spacing: 16) {
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
                }

                settingsSection("Visible Sections") {
                    toggleRow("Recently Played Albums", isOn: showRecentlyPlayedBinding)
                    dividerRow
                    toggleRow("Recently Added Albums", isOn: showRecentlyAddedBinding)
                    if isPlexSource {
                        dividerRow
                        toggleRow("Playlists", isOn: showPlaylistsBinding)
                    }
                    dividerRow
                    toggleRow("Stations", isOn: showStationsBinding)
                }

                settingsSection("Playback") {
                    toggleRow("Loudness Leveling", isOn: loudnessLevelingBinding)
                    dividerRow
                    pickerRow("Scrobble Threshold", selection: listenedThresholdBinding, items: listenedThresholdOptions)
                }

                Button {
                    onSignOut()
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

    private var isPlexSource: Bool {
        settingsStore.settings.mediaSource == .plex
    }

    private var canRefreshLibrary: Bool {
        switch settingsStore.settings.mediaSource {
        case .plex:
            return authService.authToken != nil
        case .navidrome:
            return settingsStore.settings.navidromeConfig.isFilled
        case .unspecified:
            return false
        }
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

    private var themePreferenceBinding: Binding<AppThemePreference> {
        Binding {
            settingsStore.settings.themePreference
        } set: { newValue in
            settingsStore.settings.themePreference = newValue
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
