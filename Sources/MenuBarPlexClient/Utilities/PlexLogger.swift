import Foundation
import os

enum PlexLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.plextray"
    private static let library = OSLog(subsystem: subsystem, category: "library")
    private static let playback = OSLog(subsystem: subsystem, category: "playback")
    private static let queue = OSLog(subsystem: subsystem, category: "queue")
    private static let timeline = OSLog(subsystem: subsystem, category: "timeline")

    static func debug(_ message: String, category: LogCategory = .library) {
        os_log(.debug, log: category.log, "%{public}@", message as NSString)
    }

    static func info(_ message: String, category: LogCategory = .library) {
        os_log(.info, log: category.log, "%{public}@", message as NSString)
    }

    static func error(_ message: String, category: LogCategory = .library) {
        os_log(.error, log: category.log, "%{public}@", message as NSString)
    }

    enum LogCategory {
        case library
        case playback
        case queue
        case timeline

        fileprivate var log: OSLog {
            switch self {
            case .library: return PlexLog.library
            case .playback: return PlexLog.playback
            case .queue: return PlexLog.queue
            case .timeline: return PlexLog.timeline
            }
        }
    }
}
