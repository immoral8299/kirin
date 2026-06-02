import Foundation

enum PlexAPIError: LocalizedError {
    case invalidResponse
    case unsupportedResponseFormat
    case noReachableServer
    case noTracksInLibrary
    case serverSelectionRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Plex returned an invalid response."
        case .unsupportedResponseFormat:
            return "Plex response format is unsupported."
        case .noReachableServer:
            return "No reachable Plex server connection was found."
        case .noTracksInLibrary:
            return "No playable tracks were found in this library."
        case .serverSelectionRequired:
            return "Select a Plex server in settings to continue."
        }
    }
}
