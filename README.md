# MenuBarPlexClient

MenuBarPlexClient is a macOS 14+ menu bar music client for Plex with a live in-menu UI.

## Current MVP Scaffold

- Menu bar app built with SwiftUI `MenuBarExtra`.
- Status line format: `<icon> <first string> - <next string>`.
- Configurable metadata fields for both string slots:
  - Album Artist
  - Track Artist (fallback to Album Artist)
  - Track Name
  - Album Name
- Default status line format: `Track Artist (fallback) - Track Name`.
- Popup UI sections:
  - Now Playing card with album art and transport controls
  - Recently Played albums (carousel, 4 items/page)
  - Recently Added albums (carousel, 4 items/page)
  - Playlists (carousel, 8 items/page)
- Section visibility and format settings persisted in `UserDefaults`.
- Optional `Loudness Leveling` setting that uses Plex track loudness analysis when available.
- Plex external-browser PIN auth flow scaffold with token polling.
- Auth token persisted to Keychain.
- Server and music-library discovery after auth, with persisted selection.
- Home content fetched from Plex APIs with a first-page cap of 12 items per section; UI carousel handles pagination.
- Login-first prompt UI appears when not authenticated, with external-browser Plex PIN flow.
- Basic AVPlayer-backed queue playback from library tracks with next/previous/play/pause controls.
- Tracks without Plex loudness analysis fall back to normal playback volume.

## Run

```bash
swift build
swift run MenuBarPlexClient
```

## Next Implementation Steps

1. Replace mock content with real Plex API calls after auth.
2. Add image caching + robust request/error handling.
3. Improve queue behavior (shuffle/repeat, smarter previous behavior, track-end auto advance).
4. Add richer now playing metadata sync from active stream events.
