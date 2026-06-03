import Foundation

enum PlaybackStateIcon {
    static func statusSystemImageName(for state: PlaybackState) -> String {
        switch state {
        case .playing: return "play.fill"
        case .paused: return "pause.fill"
        case .stopped: return "stop.fill"
        case .buffering: return "arrow.triangle.2.circlepath"
        }
    }

    static func actionSystemImageName(for state: PlaybackState) -> String {
        switch state {
        case .playing: return "pause.fill"
        case .paused, .stopped: return "play.fill"
        case .buffering: return "play.fill"
        }
    }
}
