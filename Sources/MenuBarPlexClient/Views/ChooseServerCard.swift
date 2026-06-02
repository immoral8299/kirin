import SwiftUI

struct ChooseServerCard: View {
    @ObservedObject var authService: PlexAuthService
    @ObservedObject var libraryStore: LibraryStore
    let onSelectServer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(greetingTitle)
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Choose a Plex server to use as your default. You can change it later in settings.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.76))

            VStack(spacing: 8) {
                ForEach(libraryStore.availableServers) { server in
                    Button {
                        onSelectServer(server.id)
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
                    .interactiveCursor(disabled: libraryStore.isLoadingLibrary)
                    .disabled(libraryStore.isLoadingLibrary)
                }
            }

            if let error = libraryStore.libraryLoadError {
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
        if case let .authenticated(username) = authService.status.state {
            let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { return "Welcome to PlexTray" }
            return "Welcome, \(username)"
        }

        return "Welcome to PlexTray"
    }
}
