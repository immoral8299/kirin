# PlexTray

PlexTray is a macOS 14+ menu bar music client for Plex with a live in-menu UI.

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
- Plex music stations discovered from library hubs and played through server-managed audio queues.
- Home, play-queue, and settings tabs with shared media playback controls.
- Persisted System, Light, and Dark appearance settings with native Liquid Glass on macOS 26 and a semantic popover-material fallback on older supported macOS versions.
- Server-managed play-queue editing with Play Next, Add to Queue, reorder, remove, clear-upcoming, refresh, and shuffle controls.
- Login-first prompt UI appears when not authenticated, with external-browser Plex PIN flow.
- Basic AVPlayer-backed queue playback from library tracks with next/previous/play/pause controls.
- Plex timeline progress reporting with a configurable percentage for counting a track as listened.
- Tracks without Plex loudness analysis fall back to normal playback volume.

## Run

```bash
swift build
swift run PlexTray
```

## Release

Build a drag-and-drop `.app` and `.dmg` locally:

```bash
./scripts/release-dmg.sh
```

Optional environment variables:

- `VERSION=0.1.0`
- `BUILD_NUMBER=1`
- `BUNDLE_ID=com.yourcompany.PlexTray`
- `SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"`
- `NOTARY_PROFILE=AC_NOTARY`

## Next Implementation Steps

1. Replace mock content with real Plex API calls after auth.
2. Add image caching + robust request/error handling.
3. Improve queue behavior (repeat and smarter previous behavior).
4. Add richer now playing metadata sync from active stream events.
