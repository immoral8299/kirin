import Foundation

@MainActor
final class StoreContext {
    let mediaService: MediaService
    let settingsStore: SettingsStore
    weak var playbackEngine: PlaybackEngine?
    weak var queueManager: QueueManager?
    weak var libraryStore: LibraryStore?
    weak var timelineTracker: TimelineTracker?

    var plexService: PlexService? { mediaService as? PlexService }

    init(mediaService: MediaService, settingsStore: SettingsStore) {
        self.mediaService = mediaService
        self.settingsStore = settingsStore
    }
}
