import SwiftUI

struct CarouselContainer<Content: View>: View {
    let title: String
    @Binding var page: Int
    let maxPage: Int
    var loop = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.accent)

                Spacer()

                if maxPage > 0 {
                    Text("\(page + 1)/\(maxPage + 1)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))

                    HStack(spacing: 2) {
                        Button {
                            if loop && page == 0 {
                                page = maxPage
                            } else {
                                page = max(0, page - 1)
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(maxPage == 0 || (!loop && page == 0))
                        .interactiveCursor(disabled: maxPage == 0 || (!loop && page == 0))

                        Button {
                            if loop && page == maxPage {
                                page = 0
                            } else {
                                page = min(maxPage, page + 1)
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(maxPage == 0 || (!loop && page == maxPage))
                        .interactiveCursor(disabled: maxPage == 0 || (!loop && page == maxPage))
                    }
                }
            }

            content
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }
}
