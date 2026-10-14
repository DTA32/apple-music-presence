# CLAUDE.md

Native macOS 26 menu bar app (Swift 6, SwiftUI): Apple Music → Discord Rich Presence + Last.fm scrobbling.
Owner: Radit (muhammad.raditya@99.co), a web/infra engineer new to Apple platforms. Explain macOS concepts by analogy when it helps.
Human docs: README.md. Original plan + decisions: docs/PLAN.md.

## Commands

```sh
make test       # swift test in Packages/AMPKit — run after any logic change
make build      # xcodebuild Debug; must finish with zero warnings
make run        # build + relaunch the app
make logs       # /usr/bin/log stream for subsystem dev.dta32.applemusicpresence
make footprint  # memory as Activity Monitor shows it (use this, not ps RSS)
make test-live  # opt-in tests against the running Discord app
```

- `SDKROOT=macosx` is exported by the Makefile. This Mac has a stale Command Line Tools SDK that otherwise wins `xcrun`'s default lookup. Use it for ad-hoc `swift`/`xcodebuild` calls too.
- In zsh `log` is a builtin. Call `/usr/bin/log`.

## Structure

- `Packages/AMPKit` holds all logic that can be tested without AppKit. Put new logic here, with Swift Testing tests (`import Testing`, `#expect`).
  - `AMPCore`: models, `PlaybackEngine` (snapshots → events), `ScrobbleTracker` (threshold rules), settings + `SettingsCodec` (merge-over-defaults decoding), templates, ignore rules, `MusicScriptParser`.
  - `DiscordRPC`: IPC frames, POSIX Unix socket with its own reader thread, `DiscordIPCClient` actor, `SendThrottle`. No dependency on AMPCore, on purpose.
  - `LastFM`: signing, client (desktop auth, nowPlaying, scrobble), `ScrobbleQueue`/`ScrobbleHistory`/`ScrobbleSubmitter` actors.
  - `Artwork`: iTunes Search lookup + strict matching + disk cache.
  - `AMPPresence`: `PresenceBuilder` (state + settings → `Activity` / clear / show-until).
- `AppleMusicPresence/` is the app target: `AppModel` (the single coordinator), `Music/` (NSAppleScript + notifications), `Support/` (Keychain, hotkeys, config), `UI/`.
- The Xcode project uses a **synchronized folder** for `AppleMusicPresence/`. New files there are picked up automatically, with no pbxproj edit. Adding a package *product* does need pbxproj entries (PBXBuildFile + XCSwiftPackageProductDependency + packageProductDependencies).

## Conventions and gotchas

- The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so app code is main-actor by default. Package code is not; it uses actors and Sendable value types.
- **Compiler crash workaround (Swift 6.3.3):** don't pass method references as closures in the app target (e.g. `set: model.setX`, `action: model.doY`). Wrap them: `{ model.setX($0) }`. IRGen crashes on the reabstraction thunk.
- C callbacks (Carbon hotkey handler) must be `nonisolated` free functions.
- `Notification` isn't Sendable: pull what you need out of it before `MainActor.assumeIsolated`.
- **Never send an Apple Event to Music unless it's running**, because it would launch Music. `MusicAppSource.refresh()` guards this.
- AppleScript: don't use `st`, `nd`, `rd`, `th` as variable names (they're ordinal suffixes). Test script changes with `osascript -s s file.applescript` first.
- Music's `com.apple.Music.playerInfo` notification: play/pause fire in pairs ~20–100 ms apart (debounced 150 ms). Seeks and repeat-one fire nothing, which is why the app polls every 5 s while playing. `PersistentID` there is a signed Int64; AppleScript gives 16-digit uppercase hex (`Track.persistentID(fromSigned:)` converts).
- Presence timestamps are anchored on playback *events*, not on polls, so the progress bar doesn't jitter.
- Ordering into actors goes through `OrderedPipe`. Separate `Task { await actor.f() }` calls aren't ordered.
- Settings changes must stay backward compatible: new fields get defaults. `SettingsCodec` merges stored JSON over defaults. Optionals that users can clear must encode explicit `null` (see `HotkeySettings.encode`).
- Zero third-party dependencies is a deliberate choice. Ask before adding one.
- Secrets: `Config/Secrets.xcconfig` (gitignored) → Info.plist (`AMPDiscordClientID`, `AMPLastFMAPIKey`, `AMPLastFMSharedSecret`) → `AppConfig`.
- Radit runs portal/account setup steps (Discord developer portal, Last.fm API account, Apple ID signing) himself. Document them, don't attempt them.
