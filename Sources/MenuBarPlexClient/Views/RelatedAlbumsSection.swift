import SwiftUI

struct RelatedAlbumsSection: View {
    let albums: [MediaAlbum]
    let pendingPlaybackID: String?
    let pendingPlaybackSource: String?
    let onSelect: (MediaAlbum) -> Void
    let onPlayNext: (MediaAlbum) -> Void
    let onAddToQueue: (MediaAlbum) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related Albums")
                .font(.system(size: 12, weight: .bold, design: .rounded))

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(albums.prefix(4))) { album in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            onSelect(album)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ArtworkImage(url: album.artworkURL, placeholderSystemImage: "music.note")
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))

                                Text(album.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                Text(album.artist)
                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .interactiveCursor()
                        .pendingPlaybackPulse(pendingPlaybackID == PendingPlaybackID.album(album.id) && pendingPlaybackSource == "related-albums")

                        HStack(spacing: 6) {
                            albumQueueButton(icon: "text.line.first.and.arrowtriangle.forward", help: "Play Album Next") {
                                onPlayNext(album)
                            }
                            albumQueueButton(icon: "text.badge.plus", help: "Add Album to Queue") {
                                onAddToQueue(album)
                            }
                        }
                    }
                    .frame(width: 100, alignment: .leading)
                }
            }
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }

    private func albumQueueButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .padding(6)
                .contentShape(Rectangle())
                .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
        .interactiveCursor()
        .help(help)
    }
}
