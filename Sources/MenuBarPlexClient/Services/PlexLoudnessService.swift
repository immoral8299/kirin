import Foundation

struct PlexLoudnessService {
    private let client: PlexNetworkClient

    init(client: PlexNetworkClient) {
        self.client = client
    }

    func fetchLoudnessGain(server: PlexServer, ratingKey: String, userToken: String) async throws -> Float? {
        let token = server.accessToken ?? userToken
        let url = client.buildURL(base: server.baseURL, path: "library/metadata/\(ratingKey)")
        let data = try await client.request(url: url, token: token)
        let container = try client.mediaContainer(from: data)
        let metadataNodes = container.objectArray(for: ["Metadata", "metadata", "Track", "track"])

        guard let trackNode = metadataNodes.first ?? container.objectArray(for: ["Track", "track"]).first,
              let selectedAudioStream = selectedAudioStream(from: trackNode),
              let gain = selectedAudioStream.float(for: ["gain"]) else {
            return nil
        }

        let peak = selectedAudioStream.float(for: ["peak", "albumPeak"])
        return clampedGain(gain, peak: peak)
    }

    private func selectedAudioStream(from node: [String: Any]) -> [String: Any]? {
        let mediaArray = node.objectArray(for: ["Media", "media"])

        for media in mediaArray {
            for part in media.objectArray(for: ["Part", "part"]) {
                let streams = part.objectArray(for: ["Stream", "stream"])
                if let selectedStream = streams.first(where: { $0.string(for: ["streamType"]) == "2" && $0.string(for: ["selected"]) == "1" }) {
                    return selectedStream
                }

                if let firstAudioStream = streams.first(where: { $0.string(for: ["streamType"]) == "2" }) {
                    return firstAudioStream
                }
            }
        }

        return nil
    }

    private func clampedGain(_ gain: Float, peak: Float?) -> Float {
        let safeGain = min(max(gain, -20), 6)

        guard let peak, peak > 0 else {
            return safeGain
        }

        let allowedBoost = 20 * log10(1 / peak)
        return min(safeGain, allowedBoost)
    }
}
