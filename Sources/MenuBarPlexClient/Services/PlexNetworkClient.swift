import Foundation

struct PlexNetworkClient {
    private let session: URLSession
    private let clientIdentifier = "Kirin"
    private let productName = "Kirin"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func request(url: URL, token: String?, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              200 ..< 300 ~= http.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode.description ?? "non-HTTP"
            let responseBody = String(data: data.prefix(500), encoding: .utf8) ?? "<non-UTF8 response>"
            print("[PlexNetworkClient] \(method) \(sanitized(url)) failed with status \(statusCode): \(responseBody)")
            throw PlexAPIError.invalidResponse
        }

        return data
    }

    func requestContainer(url: URL, token: String?, method: String = "GET") async throws -> [String: Any] {
        let data = try await request(url: url, token: token, method: method)
        return try mediaContainer(from: data)
    }

    func mediaContainer(from data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any] else {
            throw PlexAPIError.unsupportedResponseFormat
        }

        if let container = root["MediaContainer"] as? [String: Any] {
            return container
        }

        return root
    }

    func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func decodeContainer<T: Decodable>(_ type: T.Type, from data: Data) throws -> PlexContainer<T> {
        let response: PlexMediaContainerResponse<T> = try JSONDecoder().decode(PlexMediaContainerResponse.self, from: data)
        return response.mediaContainer
    }

    func resourceArray(from data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)

        if let resources = json as? [[String: Any]] {
            return resources
        }

        guard let root = json as? [String: Any] else {
            throw PlexAPIError.unsupportedResponseFormat
        }

        if let container = root["MediaContainer"] as? [String: Any] {
            return container.objectArray(for: ["Resource", "resources"])
        }

        return root.objectArray(for: ["Resource", "resources"])
    }

    func buildURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        var url = base
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        guard !query.isEmpty else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        return components?.url ?? url
    }

    func bestConnectionURL(from nodes: [[String: Any]]) -> URL? {
        let urls = nodes.compactMap { node -> URL? in
            guard let uri = node.string(for: ["uri", "URL"]) else { return nil }
            return URL(string: uri)
        }

        if let https = urls.first(where: { $0.scheme?.lowercased() == "https" }) {
            return https
        }

        return urls.first
    }

    private func applyPlexHeaders(to request: inout URLRequest) {
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("14.0", forHTTPHeaderField: "X-Plex-Platform-Version")
    }

    private func sanitized(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.queryItems = components.queryItems?.map { item in
            item.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame
                ? URLQueryItem(name: item.name, value: "<redacted>")
                : item
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}
