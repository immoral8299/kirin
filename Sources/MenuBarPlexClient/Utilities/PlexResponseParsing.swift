import Foundation

extension Dictionary where Key == String, Value == Any {
    func string(for keys: [String]) -> String? {
        for key in keys {
            if let value = self[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }

            if let value = self[key] as? NSNumber {
                return value.stringValue
            }

            if let value = self[key] as? Int {
                return String(value)
            }
        }

        return nil
    }

    func int(for keys: [String]) -> Int? {
        for key in keys {
            if let value = self[key] as? Int {
                return value
            }

            if let value = self[key] as? NSNumber {
                return value.intValue
            }

            if let value = self[key] as? String,
               let intValue = Int(value) {
                return intValue
            }
        }

        return nil
    }

    func float(for keys: [String]) -> Float? {
        for key in keys {
            if let value = self[key] as? Float {
                return value
            }

            if let value = self[key] as? Double {
                return Float(value)
            }

            if let value = self[key] as? NSNumber {
                return value.floatValue
            }

            if let value = self[key] as? String,
               let floatValue = Float(value) {
                return floatValue
            }
        }

        return nil
    }

    func objectArray(for keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let objects = self[key] as? [[String: Any]] {
                return objects
            }

            if let objects = self[key] as? [Any] {
                return objects.compactMap { $0 as? [String: Any] }
            }
        }

        return []
    }
}

func firstMediaPartPath(from node: [String: Any]) -> String? {
    guard let mediaArray = node["Media"] as? [[String: Any]],
          let firstMedia = mediaArray.first,
          let partArray = firstMedia["Part"] as? [[String: Any]],
          let firstPart = partArray.first,
          let path = firstPart.string(for: ["key", "file"]) else {
        return nil
    }

    return path
}

private func plexResolvedURL(from path: String, server: PlexServer, token: String?) -> URL {
    if path.hasPrefix("http://") || path.hasPrefix("https://"), let resolved = URL(string: path) {
        return resolved
    }

    let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
    var url = server.baseURL
    for component in normalizedPath.split(separator: "/") {
        url.appendPathComponent(String(component))
    }

    guard let token else {
        return url
    }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items = components?.queryItems ?? []
    items.append(URLQueryItem(name: "X-Plex-Token", value: token))
    components?.queryItems = items
    return components?.url ?? url
}

func plexStreamURL(from path: String, server: PlexServer, token: String?) -> URL {
    if path.hasPrefix("http://") || path.hasPrefix("https://") {
        return URL(string: path) ?? server.baseURL
    }
    return plexResolvedURL(from: path, server: server, token: token)
}

func plexArtworkURL(from artworkPath: String?, server: PlexServer, token: String?) -> URL? {
    guard let artworkPath else { return nil }
    if artworkPath.hasPrefix("http://") || artworkPath.hasPrefix("https://") {
        return URL(string: artworkPath)
    }
    return plexResolvedURL(from: artworkPath, server: server, token: token)
}

func deduplicate<T: Identifiable>(_ values: [T]) -> [T] where T.ID == String {
    var seen = Set<String>()
    var unique: [T] = []

    for value in values where !seen.contains(value.id) {
        seen.insert(value.id)
        unique.append(value)
    }

    return unique
}

func nestedObjects(in value: Any) -> [[String: Any]] {
    if let object = value as? [String: Any] {
        return [object] + object.values.flatMap(nestedObjects(in:))
    }

    if let array = value as? [Any] {
        return array.flatMap(nestedObjects(in:))
    }

    return []
}

func selectedAudioStream(from node: [String: Any]) -> [String: Any]? {
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

func clampedGain(_ gain: Float, peak: Float?) -> Float {
    let safeGain = min(max(gain, -20), 6)

    guard let peak, peak > 0 else {
        return safeGain
    }

    let allowedBoost = 20 * log10(1 / peak)
    return min(safeGain, allowedBoost)
}
