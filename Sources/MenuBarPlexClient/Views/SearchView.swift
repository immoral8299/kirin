import SwiftUI

struct SearchView: View {
    let appState: AppState
    @ObservedObject private var queueManager: QueueManager

    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var results = MediaSearchResults(tracks: [], albums: [])
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let minimumQueryLength = 2
    private let resultLimit = 20

    init(appState: AppState) {
        self.appState = appState
        _queueManager = ObservedObject(wrappedValue: appState.queueManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            stateContent
        }
        .frame(width: MenuBarLayout.contentWidth, alignment: .leading)
        .task(id: query) {
            await searchAfterDebounce()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))

            TextField("Search tracks and albums", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary.opacity(0.72))
                .interactiveCursor()
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
    }

    @ViewBuilder
    private var stateContent: some View {
        let trimmedQuery = normalized(query)

        if trimmedQuery.isEmpty {
            stateMessage("Waiting for input...", icon: "sleep")
        } else if trimmedQuery.count < minimumQueryLength {
            stateMessage("Enter at least 2 characters.", icon: "text.cursor")
        } else if let errorMessage {
            stateMessage(errorMessage, icon: "exclamationmark.triangle.fill")
        } else if isLoading && searchedQuery != trimmedQuery {
            stateMessage("Searching...", icon: "magnifyingglass")
        } else if results.tracks.isEmpty && results.albums.isEmpty && searchedQuery == trimmedQuery {
            stateMessage("No results for \"\(trimmedQuery)\".", icon: "slash.circle")
        } else {
            resultsContent
        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !results.tracks.isEmpty {
                resultSection(title: "Tracks") {
                    ForEach(Array(results.tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(track)
                        if index < results.tracks.count - 1 {
                            rowDivider
                        }
                    }
                }
            }

            if !results.albums.isEmpty {
                resultSection(title: "Albums") {
                    ForEach(Array(results.albums.enumerated()), id: \.element.id) { index, album in
                        albumRow(album)
                        if index < results.albums.count - 1 {
                            rowDivider
                        }
                    }
                }
            }
        }
    }

    private func resultSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))

            LazyVStack(spacing: 0) {
                content()
            }
            .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        }
    }

    private func trackRow(_ track: MediaTrack) -> some View {
        HStack(spacing: 9) {
            ArtworkImage(url: track.artworkURL, placeholderSystemImage: "music.note")
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))

            Button {
                appState.playTracks(results.tracks, startingAt: track.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(trackSubtitle(track))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .interactiveCursor()
            .pendingPlaybackPulse(queueManager.pendingPlaybackID == PendingPlaybackID.track(track.id))

            actionButton(icon: "play.fill", help: "Play Now") {
                appState.playTracks(results.tracks, startingAt: track.id)
            }
            actionButton(icon: "text.line.first.and.arrowtriangle.forward", help: "Play Next") {
                appState.enqueueTracks([track], playNext: true)
            }
            actionButton(icon: "text.badge.plus", help: "Add to Queue") {
                appState.enqueueTracks([track], playNext: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func albumRow(_ album: MediaAlbum) -> some View {
        HStack(spacing: 9) {
            ArtworkImage(url: album.artworkURL, placeholderSystemImage: "music.note")
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))

            Button {
                appState.playAlbum(album)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(album.artist)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.68))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .interactiveCursor()
            .pendingPlaybackPulse(queueManager.pendingPlaybackID == PendingPlaybackID.album(album.id))

            actionButton(icon: "play.fill", help: "Play Now") {
                appState.playAlbum(album)
            }
            actionButton(icon: "text.line.first.and.arrowtriangle.forward", help: "Play Next") {
                appState.enqueueAlbum(album, playNext: true)
            }
            actionButton(icon: "text.badge.plus", help: "Add to Queue") {
                appState.enqueueAlbum(album, playNext: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(AppTheme.settingsDivider)
            .padding(.horizontal, 10)
    }

    private func actionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14, height: 14)
                .padding(5)
                .contentShape(Rectangle())
                .background(AppTheme.panelFillSoft, in: RoundedRectangle(cornerRadius: AppCornerRadius.compact, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(AppTheme.accent)
        .interactiveCursor()
        .help(help)
    }

    private func stateMessage(_ message: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary.opacity(0.72))
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.74))
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panelFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }

    private func searchAfterDebounce() async {
        let trimmedQuery = normalized(query)
        errorMessage = nil

        guard trimmedQuery.count >= minimumQueryLength else {
            isLoading = false
            searchedQuery = ""
            results = MediaSearchResults(tracks: [], albums: [])
            return
        }

        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            isLoading = true
            let searchResults = try await appState.searchLibrary(query: trimmedQuery, limit: resultLimit)
            guard !Task.isCancelled else { return }

            searchedQuery = trimmedQuery
            results = searchResults
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchedQuery = trimmedQuery
            results = MediaSearchResults(tracks: [], albums: [])
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trackSubtitle(_ track: MediaTrack) -> String {
        let artist = track.trackArtist ?? track.albumArtist
        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(artist) / \(track.albumName)"
        }
        return track.albumName
    }
}
