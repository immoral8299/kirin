import SwiftUI

struct PlayQueueView: View {
    @ObservedObject var appState: AppState
    @State private var showsPlayedTracks = false

    var body: some View {
        let currentTrackIndex = currentTrackIndex
        let tracks = displayedTracks(currentTrackIndex: currentTrackIndex)
        let hasUpcomingTracks = currentTrackIndex >= 0 && currentTrackIndex < appState.visiblePlayQueue.count - 1

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Play Queue")
                    .font(.system(size: 12, weight: .bold, design: .rounded))

                Spacer()

                if appState.isQueueOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    appState.refreshPlayQueue()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .disabled(!appState.hasEditablePlayQueue || appState.isQueueOperationInProgress)
                .interactiveCursor(disabled: !appState.hasEditablePlayQueue || appState.isQueueOperationInProgress)
                .help("Refresh Play Queue")

                Button {
                    appState.clearUpcomingPlayQueueTracks()
                } label: {
                    Image(systemName: "trash")
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red.opacity(0.9))
                .disabled(!hasUpcomingTracks || appState.isQueueOperationInProgress)
                .interactiveCursor(disabled: !hasUpcomingTracks || appState.isQueueOperationInProgress)
                .help("Clear Upcoming Tracks")
            }

            if currentTrackIndex > 0 {
                Button {
                    showsPlayedTracks.toggle()
                } label: {
                    Label("Played tracks", systemImage: showsPlayedTracks ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .interactiveCursor()
            }

            if !tracks.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        queueRow(track, isUpcoming: isUpcomingTrack(at: index, currentTrackIndex: currentTrackIndex))
                        if index < tracks.count - 1 {
                            Divider()
                                .overlay(AppTheme.settingsDivider)
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
            } else {
                Text("Start playback from an album, playlist, or station to create an editable queue.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.74))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
            }
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }

    private func queueRow(_ track: PlexTrack, isUpcoming: Bool) -> some View {
        let isCurrent = track.id == appState.currentPlayQueueTrackID

        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCurrent ? AppTheme.accent : Color.secondary.opacity(0.55))
                .frame(width: 16)

            Button {
                appState.selectPlayQueueTrack(id: track.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(track.trackArtist ?? track.albumArtist ?? track.albumName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.isQueueOperationInProgress)

            if isUpcoming {
                Button {
                    appState.removePlayQueueTrack(id: track.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
                .disabled(appState.isQueueOperationInProgress)
                .help("Remove Track from Play Queue")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isCurrent ? AppTheme.overlaySoft : .clear)
        .draggable(track.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let sourceID = ids.first else { return false }
            appState.movePlayQueueTrack(id: sourceID, before: track.id)
            return true
        }
    }

    private var currentTrackIndex: Int {
        appState.visiblePlayQueue.firstIndex(where: { $0.id == appState.currentPlayQueueTrackID }) ?? -1
    }

    private func displayedTracks(currentTrackIndex: Int) -> [PlexTrack] {
        guard currentTrackIndex >= 0, !showsPlayedTracks else {
            return appState.visiblePlayQueue
        }

        return Array(appState.visiblePlayQueue.dropFirst(currentTrackIndex))
    }

    private func isUpcomingTrack(at displayedTrackIndex: Int, currentTrackIndex: Int) -> Bool {
        guard currentTrackIndex >= 0 else { return false }
        let firstDisplayedTrackIndex = showsPlayedTracks ? 0 : currentTrackIndex
        return firstDisplayedTrackIndex + displayedTrackIndex > currentTrackIndex
    }
}
