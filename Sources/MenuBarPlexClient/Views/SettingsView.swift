import SwiftUI

struct SettingsView: View {
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
                    .padding(6)
                    .contentShape(Rectangle())
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
