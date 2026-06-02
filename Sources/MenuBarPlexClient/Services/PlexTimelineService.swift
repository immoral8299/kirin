import Foundation

struct PlexTimelineService {
    private let client: PlexNetworkClient

    init(client: PlexNetworkClient) {
        self.client = client
    }

    func reportPlaybackTimeline(
        server: PlexServer,
        ratingKey: String,
        playQueueID: Int?,
        playQueueItemID: String?,
        state: PlaybackState,
        positionMilliseconds: Int,
        durationMilliseconds: Int,
        userToken: String
    ) async throws {
        let token = server.accessToken ?? userToken
        var query = [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(max(positionMilliseconds, 0))),
            URLQueryItem(name: "duration", value: String(max(durationMilliseconds, 0))),
            URLQueryItem(name: "type", value: "music"),
        ]

        if let playQueueID {
            query.append(URLQueryItem(name: "playQueueID", value: String(playQueueID)))
            query.append(URLQueryItem(name: "containerKey", value: "/playQueues/\(playQueueID)"))
        }

        if let playQueueItemID {
            query.append(URLQueryItem(name: "playQueueItemID", value: playQueueItemID))
        }

        let url = client.buildURL(base: server.baseURL, path: ":/timeline", query: query)
        _ = try await client.request(url: url, token: token, method: "POST")
    }

    func markTrackListened(server: PlexServer, ratingKey: String, userToken: String) async throws {
        let token = server.accessToken ?? userToken
        let query = [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: ratingKey),
        ]
        let url = client.buildURL(base: server.baseURL, path: ":/scrobble", query: query)
        _ = try await client.request(url: url, token: token, method: "PUT")
    }
}
