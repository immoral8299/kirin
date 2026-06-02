import Foundation

struct PlexServerDiscoveryService {
    private let client: PlexNetworkClient

    init(client: PlexNetworkClient) {
        self.client = client
    }

    func fetchServers(userToken: String) async throws -> [PlexServer] {
        guard let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1") else {
            throw URLError(.badURL)
        }

        let data = try await client.request(url: url, token: userToken)
        let resources = try client.resourceArray(from: data)

        var servers: [PlexServer] = []

        for resource in resources {
            guard let provides = resource.string(for: ["provides"]),
                  provides.contains("server") else {
                continue
            }

            guard let id = resource.string(for: ["clientIdentifier", "machineIdentifier", "identifier"]),
                  let name = resource.string(for: ["name", "device", "sourceTitle"]) else {
                continue
            }

            let token = resource.string(for: ["accessToken"])
            let connections = resource.objectArray(for: ["connections", "Connection"])
            guard let baseURL = client.bestConnectionURL(from: connections) else {
                continue
            }

            servers.append(
                PlexServer(
                    id: id,
                    name: name,
                    accessToken: token,
                    baseURL: baseURL
                )
            )
        }

        let deduplicated = Dictionary(grouping: servers, by: \.id).compactMap { $0.value.first }
        return deduplicated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchMusicLibraries(server: PlexServer, userToken: String) async throws -> [PlexMusicLibrary] {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "library/sections")
        let data = try await client.request(url: url, token: token)
        let container = try client.mediaContainer(from: data)
        let directories = container.objectArray(for: ["Directory", "directory"])

        let libraries = directories.compactMap { directory -> PlexMusicLibrary? in
            guard let type = directory.string(for: ["type"])?.lowercased(), type == "artist" else {
                return nil
            }

            guard let id = directory.string(for: ["key"]),
                  let title = directory.string(for: ["title"]) else {
                return nil
            }

            return PlexMusicLibrary(id: id, title: title, uuid: directory.string(for: ["uuid"]))
        }

        return libraries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
