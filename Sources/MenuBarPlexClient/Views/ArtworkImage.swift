import SwiftUI

struct ArtworkImage: View {
    let url: URL?
    let placeholderSystemImage: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .empty:
                placeholder(isLoading: url != nil)
            case .failure:
                placeholder(isLoading: false)
            @unknown default:
                placeholder(isLoading: false)
            }
        }
    }

    private func placeholder(isLoading: Bool) -> some View {
        AppTheme.artworkPlaceholder
            .overlay {
                Image(systemName: placeholderSystemImage)
                    .foregroundStyle(.secondary.opacity(0.55))
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }
}
