import SwiftUI

struct NavidromeLoginCard: View {
    let onConnect: (NavidromeServerConfig, String) -> Void
    let onVerify: (NavidromeServerConfig, String) async throws -> Void
    let onBack: () -> Void

    @State private var serverName: String = ""
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var publicURL: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?

    private var isValid: Bool {
        !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect to Navidrome")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button("Back") {
                    onBack()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .interactiveCursor()
                .foregroundStyle(AppTheme.accent)
            }

            Text("Enter your Navidrome server details to connect.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.78))

            VStack(spacing: 8) {
                textFieldRow("Server Name", placeholder: "My Music", text: $serverName)
                textFieldRow("Server URL", placeholder: "http://192.168.1.100:4533", text: $serverURL)
                textFieldRow("Username", placeholder: "your-username", text: $username)
                secureFieldRow("Password", placeholder: "••••••••", text: $password)
                textFieldRow("Public URL (optional)", placeholder: "https://music.example.com", text: $publicURL)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.yellow)
            }

            HStack {
                Spacer()
                Button(action: connect) {
                    HStack(spacing: 6) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AppTheme.onAccent)
                        }
                        Text("Connect")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .interactiveCursor()
                .background(isValid ? AppTheme.accent : AppTheme.accent.opacity(0.4))
                .foregroundStyle(isValid ? AppTheme.onAccent : AppTheme.onAccent.opacity(0.5))
                .clipShape(Capsule())
                // .disabled(!isValid || isConnecting)
            }
        }
    }

    private func connect() {
        guard isValid else { return }
        isConnecting = true
        errorMessage = nil

        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPublicURL = publicURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard URL(string: trimmedURL) != nil else {
            errorMessage = "Invalid server URL."
            isConnecting = false
            return
        }

        let config = NavidromeServerConfig(
            name: trimmedName,
            url: trimmedURL,
            publicUrl: trimmedPublicURL.isEmpty ? nil : trimmedPublicURL,
            username: trimmedUsername
        )

        Task {
            do {
                try await onVerify(config, password)
                onConnect(config, password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func textFieldRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(width: 100, alignment: .trailing)

            TextField(placeholder, text: text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppTheme.settingsFieldFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
    }

    private func secureFieldRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
                .frame(width: 100, alignment: .trailing)

            SecureField(placeholder, text: text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppTheme.settingsFieldFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
    }
}
