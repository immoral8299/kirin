import SwiftUI

struct CarouselContainer<Content: View>: View {
    let title: String
    @Binding var page: Int
    let maxPage: Int
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

                    Button {
                        page = max(0, page - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(page == 0)
                    .interactiveCursor(disabled: page == 0)

                    Button {
                        page = min(maxPage, page + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(page == maxPage)
                    .interactiveCursor(disabled: page == maxPage)
                }
            }

            content
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
    }
}
