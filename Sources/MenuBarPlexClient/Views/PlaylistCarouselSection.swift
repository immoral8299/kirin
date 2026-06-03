import SwiftUI

struct PlaylistCarouselSection: View {
    let title: String
    let items: [MediaPlaylist]
    let pageSize: Int
    let pendingPlaybackID: String?
    let onSelect: (MediaPlaylist) -> Void
    let onPlayNext: (MediaPlaylist) -> Void
    let onAddToQueue: (MediaPlaylist) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage) {
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                if let playlist = currentItems[index] {
                                    Button {
                                        onSelect(playlist)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(playlist.title)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .lineLimit(1)
                                            Text("\(playlist.trackCount) tracks")
                                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                                .foregroundStyle(.secondary.opacity(0.74))
                                        }
                                        .offset(y: -1)
                                        .padding(12)
                                        .frame(width: 210, alignment: .leading)
                                        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .interactiveCursor()
                                    .contentShape(Rectangle())
                                    .pendingPlaybackPulse(pendingPlaybackID == PendingPlaybackID.playlist(playlist.id))
                                    .contextMenu {
                                        Button("Play Now") { onSelect(playlist) }
                                        Button("Play Next") { onPlayNext(playlist) }
                                        Button("Add to Queue") { onAddToQueue(playlist) }
                                    }
                                } else {
                                    Color.clear
                                        .frame(width: 210, height: 56)
                                }
                            }
                        }
                    }
                }
                .frame(width: MenuBarLayout.contentWidth - 4, alignment: .leading)
            }
            .onChange(of: items.count) { _ in
                page = min(page, maxPage)
            }
        }
    }

    private var maxPage: Int {
        guard !items.isEmpty else { return 0 }
        return (items.count - 1) / pageSize
    }

    private var currentItems: [MediaPlaylist?] {
        let start = page * pageSize
        guard start < items.count else {
            return Array(repeating: nil, count: pageSize)
        }

        let end = min(start + pageSize, items.count)
        let pageItems = Array(items[start..<end]).map(Optional.some)
        if pageItems.count < pageSize {
            return pageItems + Array(repeating: nil, count: pageSize - pageItems.count)
        }

        return pageItems
    }
}
