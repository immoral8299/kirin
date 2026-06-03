import SwiftUI

struct WelcomeCard: View {
    @Binding var mediaSource: ActiveMediaSource
    let navidromeConfig: NavidromeServerConfig
    let authState: PlexAuthStatus.State
    let onBeginPlexLogin: () -> Void
    let onOpenBrowser: () -> Void
    let onConfigureNavidrome: (NavidromeServerConfig, String) -> Void
    let onVerifyNavidrome: (NavidromeServerConfig, String) async throws -> Void
    let onPinChange: (Bool) -> Void
    let onImportLocalFiles: () -> Void

    @State private var showNavidromeForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showNavidromeForm {
                NavidromeLoginCard(
                    initialConfig: navidromeConfig,
                    onConnect: { config, password in
                        onConfigureNavidrome(config, password)
                    },
                    onVerify: { config, password in
                        try await onVerifyNavidrome(config, password)
                    },
                    onBack: {
                        showNavidromeForm = false
                        onPinChange(false)
                    }
                )
            } else if mediaSource == .plex {
                plexLoginContent
            } else {
                sourcePickerContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .onDisappear {
            if showNavidromeForm {
                onPinChange(false)
            }
        }
    }

    private var sourcePickerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your music server")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Choose a source to get started.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.78))

            HStack(spacing: 10) {
                sourceButton(
                    title: "Plex",
                    icon: "person.badge.key",
                    color: AppTheme.accent,
                    action: {
                        mediaSource = .plex
                        onBeginPlexLogin()
                    }
                )

                sourceButton(
                    title: "Navidrome",
                    icon: "music.note.list",
                    color: AppTheme.accent,
                    action: {
                        showNavidromeForm = true
                        onPinChange(true)
                    }
                )

                sourceButton(
                    title: "Local Files",
                    icon: "music.note",
                    color: AppTheme.accent,
                    action: {
                        onImportLocalFiles()
                    }
                )
            }
        }
    }

    private func sourceButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .frame(height: 28)
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(color.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .interactiveCursor()
    }

    @ViewBuilder
    private var plexLoginContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect your Plex account")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button("Back") {
                    mediaSource = .unspecified
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .interactiveCursor()
                .foregroundStyle(AppTheme.accent)
            }

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
                    plexConnectButton
                }
            default:
                plexConnectButton
            }
        }
    }

    private var plexConnectButton: some View {
        Button {
            onBeginPlexLogin()
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
