import SwiftUI

struct EmptyLibraryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Library connected")
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text("No recent albums or playlists were returned. Try another library in settings or refresh.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }
}
