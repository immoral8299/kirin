import SwiftUI

struct QueueStationRecommendationsSection: View {
    let recommendations: [PlexStationRecommendation]
    let pendingPlaybackID: String?
    let onSelect: (PlexStationRecommendation) -> Void
    let onAddToQueue: (PlexStationRecommendation) -> Void

    var body: some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stations")
                    .font(.system(size: 12, weight: .bold, design: .rounded))

                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(recommendations) { recommendation in
                        stationCard(recommendation)
                    }
                }
            }
            .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
        }
    }

    private func stationCard(_ recommendation: PlexStationRecommendation) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelect(recommendation)
            } label: {
                HStack(spacing: 8) {
                    ArtworkImage(url: recommendation.artworkURL, placeholderSystemImage: "radio")
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(recommendation.title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text(recommendation.subtitle)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.68))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .interactiveCursor()
            .help("Play \(recommendation.subtitle)")

            Button {
                onAddToQueue(recommendation)
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .interactiveCursor()
            .help("Add \(recommendation.subtitle) to Queue")
        }
        .padding(8)
        .frame(width: 210, height: 58, alignment: .leading)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        .pendingPlaybackPulse(pendingPlaybackID == PendingPlaybackID.recommendation(recommendation.id))
    }

    private var columns: [GridItem] {
        [
            GridItem(.fixed(210), spacing: 8),
            GridItem(.fixed(210), spacing: 8),
        ]
    }
}
