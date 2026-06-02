import Foundation

@MainActor
final class StoreContext {
    let plexService: PlexService
    let settingsStore: SettingsStore
    weak var playbackEngine: PlaybackEngine?
    weak var queueManager: QueueManager?
    weak var libraryStore: LibraryStore?
    weak var timelineTracker: TimelineTracker?

    init(plexService: PlexService, settingsStore: SettingsStore) {
        self.plexService = plexService
        self.settingsStore = settingsStore
    }
}
