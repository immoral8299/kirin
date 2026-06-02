import Foundation

@MainActor
final class TimelineTracker {
    private let context: StoreContext
    private var trackedTrack: PlexTrack?
    private var hasMarkedTrackedTrackListened = false
    private var periodicReportingTask: Task<Void, Never>?
    private var timelineRequestTask: Task<Void, Never>?
    private let timelineReportInterval: TimeInterval = 10

    var listenedThresholdPercentage: Int {
        context.settingsStore.settings.listenedThresholdPercentage
    }

    init(context: StoreContext) {
        self.context = context
    }

    func setListenedThresholdPercentage(_ percentage: Int) {
        context.settingsStore.settings.listenedThresholdPercentage = min(max(percentage, 50), 100)
        markTrackedTrackListenedIfNeeded()
    }

    func beginTracking(_ track: PlexTrack) {
        guard trackedTrack?.id != track.id else { return }
        stopTrackingCurrentTrack()
        trackedTrack = track
        hasMarkedTrackedTrackListened = false
        periodicReportingTask?.cancel()
        periodicReportingTask = nil
    }

    func stopTrackingCurrentTrack() {
        guard trackedTrack != nil else { return }
        reportTrackedPlaybackTimeline(state: .stopped)
        periodicReportingTask?.cancel()
        periodicReportingTask = nil
        trackedTrack = nil
        hasMarkedTrackedTrackListened = false
    }

    func stopTracking() {
        stopTrackingCurrentTrack()
    }

    func playbackStateDidChange(to state: PlaybackState) {
        periodicReportingTask?.cancel()
        periodicReportingTask = nil

        guard state == .playing else {
            if state == .paused || state == .stopped {
                reportTrackedPlaybackTimeline(state: state)
            }
            return
        }

        reportTrackedPlaybackTimeline(state: .playing)
        periodicReportingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.timelineReportInterval ?? 10))
                guard !Task.isCancelled else { return }
                self?.reportTrackedPlaybackTimeline(state: .playing)
            }
        }
    }

    func reportTrackedPlaybackTimeline(state: PlaybackState) {
        guard let track = trackedTrack,
              let ratingKey = track.ratingKey,
              let server = context.libraryStore?.selectedServer,
              let userToken = context.plexService.authService.authToken else {
            return
        }

        let positionMilliseconds = Int(((context.playbackEngine?.playbackPosition ?? 0) * 1_000).rounded())
        let durationMilliseconds = resolvedDurationMilliseconds(for: track)
        let previousTimelineRequestTask = timelineRequestTask
        timelineRequestTask = Task {
            await previousTimelineRequestTask?.value

            do {
                try await context.plexService.reportPlaybackTimeline(
                    server: server,
                    ratingKey: ratingKey,
                    playQueueID: context.queueManager?.hasEditablePlayQueue == true ? 0 : nil,
                    playQueueItemID: track.playQueueItemID,
                    state: state,
                    positionMilliseconds: positionMilliseconds,
                    durationMilliseconds: durationMilliseconds,
                    userToken: userToken
                )
            } catch {
                logDebug("Timeline update failed for \(track.title): \(error.localizedDescription)")
            }
        }
    }

    func markTrackedTrackListenedIfNeeded(force: Bool = false) {
        guard !hasMarkedTrackedTrackListened,
              let track = trackedTrack,
              let ratingKey = track.ratingKey,
              let server = context.libraryStore?.selectedServer,
              let userToken = context.plexService.authService.authToken else {
            return
        }

        let durationMilliseconds = resolvedDurationMilliseconds(for: track)
        guard durationMilliseconds > 0 else { return }

        let position = context.playbackEngine?.playbackPosition ?? 0
        let listenedPercentage = (position * 1_000 / Double(durationMilliseconds)) * 100
        guard force || listenedPercentage >= Double(listenedThresholdPercentage) else { return }

        hasMarkedTrackedTrackListened = true
        Task {
            do {
                try await context.plexService.markTrackListened(server: server, ratingKey: ratingKey, userToken: userToken)
                logDebug("Marked \(track.title) listened at \(Int(listenedPercentage.rounded()))%")
            } catch {
                if trackedTrack?.id == track.id {
                    hasMarkedTrackedTrackListened = false
                }
                logDebug("Listened update failed for \(track.title): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    private func resolvedDurationMilliseconds(for track: PlexTrack) -> Int {
        if trackedTrack?.id == track.id,
           let playbackDuration = context.playbackEngine?.playbackDuration,
           playbackDuration.isFinite,
           playbackDuration > 0 {
            return Int((playbackDuration * 1_000).rounded())
        }
        return track.durationMilliseconds ?? 0
    }

    private func logDebug(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        print("[\(formatter.string(from: Date()))] \(message)")
    }
}
