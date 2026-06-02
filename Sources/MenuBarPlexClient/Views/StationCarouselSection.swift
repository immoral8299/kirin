import SwiftUI

struct StationCarouselSection: View {
    let title: String
    let items: [PlexStation]
    let pageSize: Int
    let onSelect: (PlexStation) -> Void
    let onPlayNext: (PlexStation) -> Void
    let onAddToQueue: (PlexStation) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage) {
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                if let station = currentItems[index] {
                                    Button {
                                        onSelect(station)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "radio")
                                                .foregroundStyle(AppTheme.accent)
                                            Text(station.title)
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .lineLimit(2)
                                        }
                                        .offset(y: -1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .frame(width: 210, height: 56, alignment: .leading)
                                        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .interactiveCursor()
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("Play Now") { onSelect(station) }
                                        Button("Play Next") { onPlayNext(station) }
                                        Button("Add to Queue") { onAddToQueue(station) }
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

    private var currentItems: [PlexStation?] {
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
