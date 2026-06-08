# AGENTS.md

This file is the starting point for AI agents working on Kirin.

## Project Shape

Kirin is a macOS 13+ SwiftUI menu bar music client for Plex, Navidrome, and local files. It is a Swift Package executable named `Kirin`.

Important directories:

- `Sources/MenuBarPlexClient/`: app source.
- `Sources/MenuBarPlexClient/Services/`: playback, queue, media-source, timeline, library, and update services.
- `Sources/MenuBarPlexClient/Models/`: shared models and settings.
- `Sources/MenuBarPlexClient/Views/`: SwiftUI views for the menu bar popup.
- `Packaging/`: release plist and app icon source.
- `scripts/`: release and icon helper scripts.
- `docs/reviews/`: prior architecture/review notes.

## Common Commands

Build:

```bash
swift build
```

Run locally:

```bash
swift run Kirin
```

Build with temporary module caches when sandboxed:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/menu-bar-plex-client-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/menu-bar-plex-client-swiftpm-cache \
swift build
```

Create a local release artifact:

```bash
./scripts/release-dmg.sh
```

## Architecture Notes

- `AppState` wires the app together and forwards UI actions to the service layer.
- `StoreContext` is the shared dependency container used by services to reach each other.
- `MediaService` is the source-neutral protocol. `PlexService`, `NavidromeService`, and `LocalService` implement source-specific behavior.
- `QueueManager` owns queue order, current index, queue editing, server-managed queue snapshots, and prebuffer hints.
- `PlaybackEngine` owns `AVPlayer`, macOS Now Playing integration, remote commands, buffering state, and playback timing.
- `LibraryStore` owns home content, server/library selection, related albums, and queue station recommendations.
- `TimelineTracker` reports playback progress and listened state to server-backed sources.

## Settings And Profiles

Settings are stored in `UserDefaults` through `SettingsStore`.

Profiles are important:

- Plex settings live under a profile key derived from the authenticated username.
- Navidrome settings live under a profile key derived from the connection name.
- Local file settings live under the `local-files` profile.

Keep local file path persistence in the `local-files` profile. `AppState.persistCurrentPlayQueue()` writes `localQueue` only when `activeMediaSource == .local`.

Credentials do not belong in `UserDefaults`; use `KeychainStore`.

## Queue And Playback Rules

- UI queue state should go through `QueueManager`.
- Actual audio state should go through `PlaybackEngine`.
- Do not mutate `AVPlayer` directly outside `PlaybackEngine`.
- Do not fetch a launch preview from Plex "Recently Played"; the app restores the persisted queue snapshot instead.
- When playback reaches the final queue item, keep the final track selected and transition to `.paused`, not `.buffering`.
- Local queue persistence has two layers:
  - `lastPlayQueue`: source-profile queue snapshot used for launch restore.
  - `localQueue`: legacy local-file path list scoped to `local-files`, kept for migration/fallback.

## UI Guidance

The app is a compact utility, not a marketing page. Keep UI dense, predictable, and consistent with existing SwiftUI patterns. Prefer editing existing components and constants over introducing new visual systems.

## Verification

At minimum, run `swift build` after Swift changes. For playback or queue changes, manually inspect these flows when possible:

- Start with a saved queue and relaunch; the queue and current track should restore without auto-playing.
- Finish the final queue item; status should become paused.
- Edit queue order, remove tracks, clear upcoming tracks, and relaunch.
- In local mode, imported file paths should persist under the `local-files` profile.

## Git Hygiene

The worktree may contain user changes. Do not revert files you did not edit. Keep changes scoped, and avoid unrelated formatting churn.
