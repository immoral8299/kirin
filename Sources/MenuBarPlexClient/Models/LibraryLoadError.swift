import Foundation

struct LibraryLoadError: Identifiable, LocalizedError {
    let id: UUID
    let message: String
    let recoveryActions: [RecoveryAction]

    enum RecoveryAction: Hashable {
        case retry
        case dismiss
        case serverSelection
        case reauthenticate
    }

    var errorDescription: String? { message }
}

extension LibraryLoadError {
    init(_ error: Error) {
        self.id = UUID()
        self.message = error.localizedDescription

        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .serverSelectionRequired:
                self.recoveryActions = [.serverSelection, .dismiss]
            case .noReachableServer:
                self.recoveryActions = [.retry, .serverSelection, .dismiss]
            default:
                self.recoveryActions = [.retry, .dismiss]
            }
        } else if error is URLError {
            self.recoveryActions = [.retry, .dismiss]
        } else {
            self.recoveryActions = [.dismiss]
        }
    }
}
