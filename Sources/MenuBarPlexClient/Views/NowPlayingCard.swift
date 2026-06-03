import SwiftUI

struct NowPlayingCard: View, Equatable {
    let metadata: TrackMetadata
    let playbackState: PlaybackState
    let playbackProgress: Double
    let playbackPosition: Double
    let playbackDuration: Double
    let isShuffleEnabled: Bool
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSeek: (Double) -> Void
    let onToggleShuffle: () -> Void
    @State private var sliderValue: Double = 0
    @State private var isSeeking = false

    nonisolated static func == (lhs: NowPlayingCard, rhs: NowPlayingCard) -> Bool {
        lhs.metadata == rhs.metadata &&
            lhs.playbackState == rhs.playbackState &&
            lhs.playbackProgress == rhs.playbackProgress &&
            lhs.playbackPosition == rhs.playbackPosition &&
            lhs.playbackDuration == rhs.playbackDuration &&
            lhs.isShuffleEnabled == rhs.isShuffleEnabled
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkImage(url: metadata.artworkURL, placeholderSystemImage: "music.note.list")
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(metadata.trackName)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if let trackNumberLabel {
                                Text(trackNumberLabel)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.68))
                                    .lineLimit(1)
                            }
                        }
                        Text(metadata.resolvedTrackArtist)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.82))
                            .lineLimit(1)
                        Text(metadata.albumName)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.68))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 16) {
                        transportButton(icon: "backward.fill", action: onPrevious)
                        transportButton(
                            icon: PlaybackStateIcon.actionSystemImageName(for: playbackState),
                            showsProgress: playbackState == .buffering,
                            action: onPlayPause
                        )
                        transportButton(icon: "forward.fill", action: onNext)
                        transportButton(icon: "shuffle", isActive: isShuffleEnabled, action: onToggleShuffle)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 128, alignment: .topLeading)
            }

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isSeeking ? sliderValue : playbackProgress },
                        set: { newValue in
                            isSeeking = true
                            sliderValue = newValue
                            onSeek(newValue)
                        }
                    ),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        isSeeking = editing
                    }
                )
                .tint(AppTheme.accent)

                HStack {
                    Text(formattedTime(playbackPosition))
                    Spacer()
                    Text(formattedTime(playbackDuration))
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.68))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .onChange(of: playbackProgress) { newValue in
            if !isSeeking {
                sliderValue = newValue
            }
        }
    }

    private func transportButton(
        icon: String,
        isActive: Bool = false,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .offset(y: -1)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .background((isActive ? AppTheme.accentActiveBackground : AppTheme.transportFill), in: Circle())
        }
        .buttonStyle(.plain)
        .interactiveCursor()
        .foregroundStyle(isActive ? AppTheme.accent : Color.primary)
    }

    private var trackNumberLabel: String? {
        guard let trackNumber = metadata.trackNumber else { return nil }

        if let discNumber = metadata.discNumber {
            return "\(discNumber).\(trackNumber)"
        }

        return "Nr. \(trackNumber)"
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
