import SwiftUI

struct LoginPromptCard: View {
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
