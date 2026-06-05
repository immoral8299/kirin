import SwiftUI
import UniformTypeIdentifiers

struct PlayQueueView: View {
    @ObservedObject var queueManager: QueueManager
    let onSelectTrack: (String) -> Void
    let onRemoveTrack: (String) -> Void
    let onMoveTrack: (String, String?) -> Void
    let onClearUpcomingTracks: () -> Void
    var isLocalMode: Bool = false
    var onImportLocalFiles: (() -> Void)?
    @State private var showsPlayedTracks = false
    @State private var draggedTrackID: String?
    @State private var previewTrackIDs: [String] = []

    var body: some View {
        let currentTrackIndex = currentTrackIndex
        let tracks = displayedTracks(currentTrackIndex: currentTrackIndex)
        let hasUpcomingTracks = currentTrackIndex >= 0 && currentTrackIndex < queueManager.visiblePlayQueue.count - 1
        let visibleTrackIDs = queueManager.visiblePlayQueue.map(\.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Play Queue")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.accent)

                Spacer()

                if queueManager.isQueueOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                if isLocalMode {
                    Button {
                        onImportLocalFiles?()
                    } label: {
                        Image(systemName: "plus")
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .interactiveCursor()
                    .help("Choose Music")
                }

                Button {
                    onClearUpcomingTracks()
                } label: {
                    Image(systemName: "trash")
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red.opacity(0.9))
                .disabled(!hasUpcomingTracks || queueManager.isQueueOperationInProgress)
                .interactiveCursor(disabled: !hasUpcomingTracks || queueManager.isQueueOperationInProgress)
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
                let previewTracks = reorderedPreviewTracks(from: tracks)
                LazyVStack(spacing: 0) {
                    ForEach(Array(previewTracks.enumerated()), id: \.element.id) { index, track in
                        let isUpcoming = isUpcomingTrack(track, currentTrackIndex: currentTrackIndex)
                        queueRow(
                            track,
                            isUpcoming: isUpcoming,
                            canReorder: canReorderTrack(track, currentTrackIndex: currentTrackIndex),
                            currentTrackIndex: currentTrackIndex,
                            displayedTracks: tracks
                        )
                        .scaleEffect(draggedTrackID == track.id ? 1.015 : 1)
                        .shadow(
                            color: .black.opacity(draggedTrackID == track.id ? 0.24 : 0),
                            radius: draggedTrackID == track.id ? 16 : 0,
                            y: draggedTrackID == track.id ? 10 : 0
                        )
                        .zIndex(draggedTrackID == track.id ? 1 : 0)
                        .animation(.snappy(duration: 0.16), value: previewTrackIDs)
                        if index < previewTracks.count - 1 {
                            Divider()
                                .overlay(AppTheme.settingsDivider)
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
                .onDrop(
                    of: [UTType.plainText.identifier],
                    delegate: QueueListDropDelegate(onDropOutside: resetDragPreview)
                )
            } else {
                if isLocalMode {
                    VStack(spacing: 10) {
                        Text("No tracks in queue.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.74))

                        Button {
                            onImportLocalFiles?()
                        } label: {
                            Label("Choose Music", systemImage: "music.note.list")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(AppTheme.accent, in: Capsule())
                                .foregroundStyle(AppTheme.onAccent)
                        }
                        .buttonStyle(.plain)
                        .interactiveCursor()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
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
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
        .onChange(of: visibleTrackIDs) { newTrackIDs in
            guard !previewTrackIDs.isEmpty,
                  previewTrackIDs.allSatisfy({ newTrackIDs.contains($0) }) else {
                return
            }

            resetDragPreview()
        }
    }

    private func queueRow(
        _ track: MediaTrack,
        isUpcoming: Bool,
        canReorder: Bool,
        currentTrackIndex: Int,
        displayedTracks: [MediaTrack]
    ) -> some View {
        let isCurrent = track.id == queueManager.currentPlayQueueTrackID

        return queueRowContent(track, isUpcoming: isUpcoming, isCurrent: isCurrent)
            .background(isCurrent ? AppTheme.overlaySoft : .clear)
            .contentShape(Rectangle())
            .modifier(
                QueueDragDropModifier(
                    trackID: track.id,
                    isEnabled: isUpcoming && !queueManager.isQueueOperationInProgress,
                    onDragStart: {
                        guard canReorder else { return }
                        draggedTrackID = track.id
                        previewTrackIDs = displayedTracks.map(\.id)
                    },
                    dropDelegate: QueueTrackDropDelegate(
                        targetID: track.id,
                        isEnabled: canReorder || isCurrent,
                        draggedTrackID: { draggedTrackID },
                        onDropEntered: { sourceID, targetID, placeAfterTarget in
                            updateDragPreview(
                                sourceID: sourceID,
                                targetID: targetID,
                                placeAfterTarget: placeAfterTarget,
                                currentTrackIndex: currentTrackIndex,
                                displayedTracks: displayedTracks
                            )
                        },
                        onPerformDrop: { sourceID in
                            commitDrag(sourceID: sourceID)
                        }
                    )
                )
            )
    }

    private func queueRowContent(_ track: MediaTrack, isUpcoming: Bool, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCurrent ? AppTheme.accent : Color.secondary.opacity(0.55))
                .frame(width: 16)

            Button {
                showsPlayedTracks = false
                onSelectTrack(track.id)
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
            .disabled(queueManager.isQueueOperationInProgress)

            if isUpcoming {
                Button {
                    onRemoveTrack(track.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.65))
                .disabled(queueManager.isQueueOperationInProgress)
                .help("Remove Track from Play Queue")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: QueueRowMetrics.height)
    }

    private var currentTrackIndex: Int {
        queueManager.visiblePlayQueue.firstIndex(where: { $0.id == queueManager.currentPlayQueueTrackID }) ?? -1
    }

    private func displayedTracks(currentTrackIndex: Int) -> [MediaTrack] {
        guard currentTrackIndex >= 0, !showsPlayedTracks else {
            return queueManager.visiblePlayQueue
        }

        return Array(queueManager.visiblePlayQueue.dropFirst(currentTrackIndex))
    }

    private func isUpcomingTrack(_ track: MediaTrack, currentTrackIndex: Int) -> Bool {
        guard currentTrackIndex >= 0 else { return false }
        guard let trackIndex = queueManager.visiblePlayQueue.firstIndex(where: { $0.id == track.id }) else { return false }
        return trackIndex > currentTrackIndex
    }

    private func canReorderTrack(_ track: MediaTrack, currentTrackIndex: Int) -> Bool {
        isUpcomingTrack(track, currentTrackIndex: currentTrackIndex)
    }

    private func reorderedPreviewTracks(from tracks: [MediaTrack]) -> [MediaTrack] {
        guard previewTrackIDs.count == tracks.count else {
            return tracks
        }

        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let previewTracks = previewTrackIDs.compactMap { tracksByID[$0] }
        return previewTracks.count == tracks.count ? previewTracks : tracks
    }

    private func updateDragPreview(
        sourceID: String,
        targetID: String,
        placeAfterTarget: Bool,
        currentTrackIndex: Int,
        displayedTracks: [MediaTrack]
    ) {
        guard canReorderSource(sourceID, currentTrackIndex: currentTrackIndex),
              displayedTracks.contains(where: { $0.id == sourceID }) else {
            return
        }

        var ids = displayedTracks.map(\.id)
        guard let sourceIndex = ids.firstIndex(of: sourceID),
              let targetIndex = ids.firstIndex(of: targetID) else {
            return
        }

        ids.remove(at: sourceIndex)
        let targetIndexAfterRemoval = ids.firstIndex(of: targetID) ?? targetIndex
        var insertionIndex = targetIndexAfterRemoval + (placeAfterTarget ? 1 : 0)
        let firstUpcomingIndex = displayedTracks.firstIndex { canReorderTrack($0, currentTrackIndex: currentTrackIndex) } ?? ids.count
        insertionIndex = min(max(insertionIndex, firstUpcomingIndex), ids.count)

        guard ids.indices.contains(insertionIndex) || insertionIndex == ids.count else { return }
        ids.insert(sourceID, at: insertionIndex)
        guard ids != previewTrackIDs else { return }

        withAnimation(.snappy(duration: 0.16)) {
            previewTrackIDs = ids
        }
    }

    private func canReorderSource(_ sourceID: String, currentTrackIndex: Int) -> Bool {
        guard currentTrackIndex >= 0,
              let sourceIndex = queueManager.visiblePlayQueue.firstIndex(where: { $0.id == sourceID }) else {
            return false
        }
        return sourceIndex > currentTrackIndex
    }

    private func commitDrag(sourceID: String) {
        let finalIDs = previewTrackIDs
        let beforeID: String?
        if let movedIndex = finalIDs.firstIndex(of: sourceID),
           movedIndex < finalIDs.count - 1 {
            beforeID = finalIDs[movedIndex + 1]
        } else {
            beforeID = nil
        }

        onMoveTrack(sourceID, beforeID)
        draggedTrackID = nil
    }

    private func resetDragPreview() {
        draggedTrackID = nil
        previewTrackIDs = []
    }
}

private enum QueueRowMetrics {
    static let height: CGFloat = 44
}

private struct QueueDragDropModifier: ViewModifier {
    let trackID: String
    let isEnabled: Bool
    let onDragStart: () -> Void
    let dropDelegate: QueueTrackDropDelegate

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    onDragStart()
                    return NSItemProvider(object: trackID as NSString)
                } preview: {
                    Color.clear
                        .frame(width: 1, height: 1)
                }
                .onDrop(of: [UTType.plainText.identifier], delegate: dropDelegate)
        } else {
            content
                .onDrop(of: [UTType.plainText.identifier], delegate: dropDelegate)
        }
    }
}

private struct QueueTrackDropDelegate: DropDelegate {
    let targetID: String
    let isEnabled: Bool
    let draggedTrackID: () -> String?
    let onDropEntered: (String, String, Bool) -> Void
    let onPerformDrop: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled
    }

    func dropEntered(info: DropInfo) {
        updatePreview(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePreview(info: info)
        return DropProposal(operation: isEnabled ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isEnabled, let sourceID = draggedTrackID() else { return false }
        onPerformDrop(sourceID)
        return true
    }

    private func updatePreview(info: DropInfo) {
        guard isEnabled, let sourceID = draggedTrackID(), sourceID != targetID else { return }
        onDropEntered(sourceID, targetID, info.location.y > QueueRowMetrics.height / 2)
    }
}

private struct QueueListDropDelegate: DropDelegate {
    let onDropOutside: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        onDropOutside()
        return false
    }
}
