import AppKit
import Foundation

struct PlexAuthStatus: Equatable {
    enum State: Equatable {
        case idle
        case requestingPin
        case waitingForBrowserLogin(url: URL, code: String)
        case authenticated(username: String)
        case failed(message: String)
    }

    var state: State

    static let idle = PlexAuthStatus(state: .idle)
}

struct PlexPinResponse: Decodable {
    let id: Int
    let code: String
}

struct PlexPinCheckResponse: Decodable {
    let authToken: String?
}

protocol PlexAuthProviding {
    func beginLogin() async
}

@MainActor
final class PlexAuthService: ObservableObject, PlexAuthProviding {
    @Published private(set) var status: PlexAuthStatus = .idle
    @Published private(set) var authToken: String?

    private let clientIdentifier = "plextray"
    private let productName = "PlexTray"
    private let session: URLSession
    private let keychainStore = KeychainStore()
    private let tokenKey = "plex.auth.token"

    init(session: URLSession = .shared) {
        self.session = session
        self.authToken = keychainStore.read(key: tokenKey)

        if authToken != nil {
            status = PlexAuthStatus(state: .authenticated(username: "Plex User"))
        }
    }

    func beginLogin() async {
        status = PlexAuthStatus(state: .requestingPin)

        do {
            let pin = try await requestPin()
            let authURL = makeAuthURL(for: pin.code)
            status = PlexAuthStatus(state: .waitingForBrowserLogin(url: authURL, code: pin.code))
            openInBrowser(authURL)

            guard let token = try await pollForToken(pinID: pin.id, pinCode: pin.code) else {
                status = PlexAuthStatus(state: .failed(message: "Timed out waiting for Plex login."))
                return
            }

            authToken = token
            keychainStore.save(token, key: tokenKey)
            status = PlexAuthStatus(state: .authenticated(username: "Plex User"))
        } catch {
            status = PlexAuthStatus(state: .failed(message: error.localizedDescription))
        }
    }

    func signOut() {
        authToken = nil
        keychainStore.delete(key: tokenKey)
        status = .idle
    }

    func reopenBrowser() {
        guard case let .waitingForBrowserLogin(url, _) = status.state else { return }
        openInBrowser(url)
    }

    private func requestPin() async throws -> PlexPinResponse {
        var components = URLComponents(string: "https://plex.tv/api/v2/pins")
        components?.queryItems = [
            URLQueryItem(name: "strong", value: "true"),
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(PlexPinResponse.self, from: data)
    }

    private func pollForToken(pinID: Int, pinCode: String) async throws -> String? {
        let deadline = Date().addingTimeInterval(120)

        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            if let token = try await checkPin(pinID: pinID, pinCode: pinCode)?.authToken {
                return token
            }
        }

        return nil
    }

    private func checkPin(pinID: Int, pinCode: String) async throws -> PlexPinCheckResponse? {
        var components = URLComponents(string: "https://plex.tv/api/v2/pins/\(pinID)")
        components?.queryItems = [
            URLQueryItem(name: "code", value: pinCode),
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(PlexPinCheckResponse.self, from: data)
    }

    private func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func makeAuthURL(for code: String) -> URL {
        let allowed = CharacterSet.urlQueryAllowed
        let encodedClientID = clientIdentifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? clientIdentifier
        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: allowed) ?? code
        let encodedProductName = productName.addingPercentEncoding(withAllowedCharacters: allowed) ?? productName

        let fragment = "#?clientID=\(encodedClientID)&code=\(encodedCode)&context%5Bdevice%5D%5Bproduct%5D=\(encodedProductName)"
        return URL(string: "https://app.plex.tv/auth\(fragment)") ?? URL(string: "https://app.plex.tv/auth")!
    }

    private func applyPlexHeaders(to request: inout URLRequest) {
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("14.0", forHTTPHeaderField: "X-Plex-Platform-Version")
    }
}
