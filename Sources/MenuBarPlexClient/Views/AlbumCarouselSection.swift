import SwiftUI

struct AlbumCarouselSection: View {
    let title: String
    let items: [PlexAlbum]
    let pageSize: Int
    let onSelect: (PlexAlbum) -> Void
    let onPlayNext: (PlexAlbum) -> Void
    let onAddToQueue: (PlexAlbum) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage) {
                HStack(spacing: 10) {
                    ForEach(Array(currentItems.enumerated()), id: \.offset) { _, album in
                        if let album {
                            Button {
                                onSelect(album)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkImage(url: album.artworkURL, placeholderSystemImage: "music.note")
                                        .id(album.id)
                                        .frame(width: 100, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))

                                    Text(album.title)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .lineLimit(1)
                                    Text(album.artist)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary.opacity(0.72))
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .interactiveCursor()
                            .contentShape(Rectangle())
                            .frame(width: 100, alignment: .leading)
                            .contextMenu {
                                Button("Play Now") { onSelect(album) }
                                Button("Play Next") { onPlayNext(album) }
                                Button("Add to Queue") { onAddToQueue(album) }
                            }
                        } else {
                            Color.clear
                                .frame(width: 100, height: 136)
                        }
                    }
                }
                .frame(width: MenuBarLayout.contentWidth - 2, alignment: .leading)
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

    private var currentItems: [PlexAlbum?] {
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
