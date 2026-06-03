import Foundation

@MainActor
final class TimelineTracker {
    private let context: StoreContext
    private var trackedTrack: MediaTrack?
    private var hasMarkedTrackedTrackListened = false
    private var periodicReportingTask: Task<Void, Never>?
    private var timelineRequestTask: Task<Void, Never>?
    private enum TimelineConfiguration {
        static let reportInterval: TimeInterval = 10
        static let initialListenedThreshold = 90
        static let minListenedThreshold = 50
        static let maxListenedThreshold = 100
    }

    var listenedThresholdPercentage: Int {
        context.settingsStore.settings.listenedThresholdPercentage
    }

    init(context: StoreContext) {
        self.context = context
    }

    func setListenedThresholdPercentage(_ percentage: Int) {
        context.settingsStore.settings.listenedThresholdPercentage = min(max(percentage, TimelineConfiguration.minListenedThreshold), TimelineConfiguration.maxListenedThreshold)
        markTrackedTrackListenedIfNeeded()
    }

    func beginTracking(_ track: MediaTrack) {
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
                try? await Task.sleep(for: .seconds(TimelineConfiguration.reportInterval))
                guard !Task.isCancelled else { return }
                self?.reportTrackedPlaybackTimeline(state: .playing)
            }
        }
    }

    func reportTrackedPlaybackTimeline(state: PlaybackState) {
        guard let track = trackedTrack else {
            return
        }

        let positionMilliseconds = Int(((context.playbackEngine?.playbackPosition ?? 0) * 1_000).rounded())
        let durationMilliseconds = resolvedDurationMilliseconds(for: track)
        let previousTimelineRequestTask = timelineRequestTask
        timelineRequestTask = Task {
            await previousTimelineRequestTask?.value

            do {
                try await context.mediaService.reportPlaybackTimeline(
                    ratingKey: track.ratingKey ?? track.id,
                    playQueueID: context.queueManager?.currentServerPlayQueueID,
                    playQueueItemID: track.playQueueItemID,
                    state: state,
                    positionMilliseconds: positionMilliseconds,
                    durationMilliseconds: durationMilliseconds
                )
            } catch {
                logDebug("Timeline update failed for \(track.title): \(error.localizedDescription)")
            }
        }
    }

    func markTrackedTrackListenedIfNeeded(force: Bool = false) {
        guard !hasMarkedTrackedTrackListened,
              let track = trackedTrack else {
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
                try await context.mediaService.markTrackListened(ratingKey: track.ratingKey ?? track.id)
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

    private func resolvedDurationMilliseconds(for track: MediaTrack) -> Int {
        if trackedTrack?.id == track.id,
           let playbackDuration = context.playbackEngine?.playbackDuration,
           playbackDuration.isFinite,
           playbackDuration > 0 {
            return Int((playbackDuration * 1_000).rounded())
        }
        return track.durationMilliseconds ?? 0
    }

    private func logDebug(_ message: String) {
        PlexLog.debug(message, category: .timeline)
    }
}
