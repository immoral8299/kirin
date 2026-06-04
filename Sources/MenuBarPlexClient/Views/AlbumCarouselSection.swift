import SwiftUI

struct AlbumCarouselSection: View {
    let title: String
    let items: [MediaAlbum]
    let pageSize: Int
    let sectionID: String
    let pendingPlaybackID: String?
    let pendingPlaybackSource: String?
    let onSelect: (MediaAlbum) -> Void
    let onPlayNext: (MediaAlbum) -> Void
    let onAddToQueue: (MediaAlbum) -> Void
    @State private var page = 0
    @State private var pageAnimationTask: Task<Void, Never>?
    @State private var displayedItems: [MediaAlbum?] = []
    @State private var previousPage = 0

    var body: some View {
        if !items.isEmpty {
            CarouselContainer(title: title, page: $page, maxPage: maxPage, loop: true) {
                HStack(spacing: 10) {
                    ForEach(Array(displayedItems.enumerated()), id: \.offset) { _, album in
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
                            .pendingPlaybackPulse(pendingPlaybackID == PendingPlaybackID.album(album.id) && pendingPlaybackSource == sectionID)
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
            .onAppear {
                if displayedItems.isEmpty {
                    displayedItems = currentPageItems(for: page)
                    previousPage = page
                }
            }
            .onChange(of: page) { _ in
                let direction = animationDirection(from: previousPage, to: page)
                previousPage = page
                startPageAnimation(direction: direction)
            }
            .onChange(of: items.count) { _ in
                let clampedPage = min(page, maxPage)
                if clampedPage != page {
                    page = clampedPage
                    return
                }
                displayedItems = currentPageItems(for: page)
                previousPage = page
                startPageAnimation(direction: .forward)
            }
        }
    }

    private var maxPage: Int {
        guard !items.isEmpty else { return 0 }
        return (items.count - 1) / pageSize
    }

    private func currentPageItems(for page: Int) -> [MediaAlbum?] {
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

    private enum AnimationDirection {
        case forward
        case backward
    }

    private func animationDirection(from previousPage: Int, to newPage: Int) -> AnimationDirection {
        if previousPage == newPage {
            return .forward
        }

        if previousPage == maxPage && newPage == 0 {
            return .forward
        }

        if previousPage == 0 && newPage == maxPage {
            return .backward
        }

        return newPage > previousPage ? .forward : .backward
    }

    private func startPageAnimation(direction: AnimationDirection) {
        pageAnimationTask?.cancel()

        let targetItems = currentPageItems(for: page)
        pageAnimationTask = Task { @MainActor in
            guard displayedItems.count == pageSize else {
                displayedItems = targetItems
                return
            }

            let indices = direction == .forward ? Array(0..<pageSize) : Array((0..<pageSize).reversed())

            for (position, index) in indices.enumerated() {
                if Task.isCancelled { return }

                if position > 0 {
                    try? await Task.sleep(for: .milliseconds(45))
                    if Task.isCancelled { return }
                }

                withAnimation(.easeOut(duration: 0.18)) {
                    displayedItems[index] = targetItems[index]
                }
            }
        }
    }
}
