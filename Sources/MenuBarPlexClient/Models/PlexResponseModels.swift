import Foundation

// MARK: - Plex MediaContainer Response

struct PlexMediaContainerResponse<T: Decodable>: Decodable {
    let mediaContainer: PlexContainer<T>

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

struct PlexContainer<T: Decodable>: Decodable {
    let metadata: [T]?
    let directory: [PlexLibraryItem]?
    let server: [PlexServerItem]?

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
        case directory = "Directory"
        case server = "Server"
    }
}

// MARK: - Track

struct PlexTrackItem: Decodable {
    let ratingKey: String
    let key: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let type: String?
    let title: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let originalTitle: String?
    let index: Int?
    let parentIndex: Int?
    let thumb: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let art: String?
    let duration: Int?
    let media: [PlexMediaItem]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, parentRatingKey, grandparentRatingKey
        case type, title, grandparentTitle, parentTitle, originalTitle
        case index, parentIndex
        case thumb, parentThumb, grandparentThumb, art
        case duration
        case media = "Media"
    }
}

struct PlexMediaItem: Decodable {
    let part: [PlexPartItem]?

    enum CodingKeys: String, CodingKey {
        case part = "Part"
    }
}

struct PlexPartItem: Decodable {
    let key: String?
    let file: String?
}

// MARK: - Server

struct PlexServerItem: Decodable {
    let name: String?
    let address: String?
    let port: Int?
    let host: String?
    let localAddresses: String?
    let machineIdentifier: String?
    let accessToken: String?
    let owned: Bool?
    let scheme: String?
    let createdAt: Int?
    let updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case name, address, port, host, localAddresses
        case machineIdentifier, accessToken, owned, scheme
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        localAddresses = try container.decodeIfPresent(String.self, forKey: .localAddresses)
        machineIdentifier = try container.decodeIfPresent(String.self, forKey: .machineIdentifier)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        owned = try container.decodeIfPresent(Bool.self, forKey: .owned) ?? (try container.decodeIfPresent(Int.self, forKey: .owned) != nil)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }
}

// MARK: - Library

struct PlexLibraryItem: Decodable {
    let key: String?
    let title: String?
    let type: String?
    let agent: String?
    let scanner: String?
    let language: String?
    let uuid: String?
    let updatedAt: Int?
    let createdAt: Int?
}
