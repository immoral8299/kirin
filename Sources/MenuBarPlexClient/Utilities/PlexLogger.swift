import Foundation
import os

enum PlexLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.Kirin"
    private static let library = OSLog(subsystem: subsystem, category: "library")
    private static let playback = OSLog(subsystem: subsystem, category: "playback")
    private static let queue = OSLog(subsystem: subsystem, category: "queue")
    private static let timeline = OSLog(subsystem: subsystem, category: "timeline")

    static func debug(_ message: String, category: LogCategory = .library) {
        os_log(.debug, log: category.log, "%{public}@", message as NSString)
        writeToStandardError(level: "debug", message: message, category: category)
    }

    static func info(_ message: String, category: LogCategory = .library) {
        os_log(.info, log: category.log, "%{public}@", message as NSString)
        writeToStandardError(level: "info", message: message, category: category)
    }

    static func error(_ message: String, category: LogCategory = .library) {
        os_log(.error, log: category.log, "%{public}@", message as NSString)
        writeToStandardError(level: "error", message: message, category: category)
    }

    private static func writeToStandardError(level: String, message: String, category: LogCategory) {
        let line = "[Kirin][\(level)][\(category.name)] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
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

        fileprivate var name: String {
            switch self {
            case .library: return "library"
            case .playback: return "playback"
            case .queue: return "queue"
            case .timeline: return "timeline"
            }
        }
    }
}
