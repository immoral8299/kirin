import Foundation

@MainActor
final class StoreContext {
    var mediaService: MediaService
    let settingsStore: SettingsStore
    weak var playbackEngine: PlaybackEngine?
    weak var queueManager: QueueManager?
    weak var libraryStore: LibraryStore?
    weak var timelineTracker: TimelineTracker?

    var plexService: PlexService? { mediaService as? PlexService }
    var navidromeService: NavidromeService? { mediaService as? NavidromeService }
    var localService: LocalService? { mediaService as? LocalService }

    init(mediaService: MediaService, settingsStore: SettingsStore) {
        self.mediaService = mediaService
        self.settingsStore = settingsStore
    }
}
