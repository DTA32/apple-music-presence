# Apple Music Presence — Discord Presence + Last.fm Scrobbler for Apple Music (native macOS)

> Created by: Radit · Drafted with Claude · 2026-10-14
> Status: **Implemented**, see §13 for spike findings and deviations. Radit's decisions are in §12.

---

## 0. TL;DR

A single **native Swift menu bar app** (no Dock icon, no window unless you open Settings) that:

1. **Watches Apple Music** using the system notification `Music.app` posts on every play/pause/track change, plus cheap Apple Events queries for the playhead position.
2. **Sets Discord Rich Presence** ("Listening to Apple Music": title, artist, album art, progress bar, buttons) by writing directly to the Discord desktop client's local IPC socket. You don't set up a bot or a token, and nothing on Discord's side needs configuring from you as a user.
3. **Scrobbles to Last.fm**: "Connect Last.fm" opens the browser, you click *Allow*, and you're done. It sends Now Playing updates, scrobbles with fully customisable rules (percent threshold, time cap, minimum length), and keeps an offline queue.

**Memory goal:** under **50 MB physical footprint** (the "Memory" column in Activity Monitor, checked with `footprint -p <pid>`) at idle, and **flat over days**. Today you're at **~1 GB** (measured 2026-10-14):

| Process | Footprint (now / peak) | RSS | Uptime | Note |
|---|---|---|---|---|
| Last.fm Scrobbler | **892 MB** / 939 MB | 47 MB | 23 days | `x86_64` under Rosetta; footprint grows with uptime → looks like a leak |
| Music Presence | 99 MB / 157 MB | 43 MB | 1.6 days | |
| ↳ `perl SystemMediaAdapter.pl` | 8 MB | 10 MB | | Music Presence's MediaRemote workaround |
| **Total** | **~1 GB** | ~100 MB | | |

> Use footprint, not RSS. RSS only counts pages currently resident in RAM. Footprint also counts this process's dirty memory that macOS has **compressed or swapped out**. For an app that leaks and then idles for weeks, most of the leak gets compressed, so RSS stays low while footprint, the memory it really costs you, reaches ~900 MB.

**Toolchain:** Xcode (decided). The core logic lives in a local Swift package, so you can also run `swift test` from the terminal like any other project.

**Effort:** about 8 focused days for someone new to Apple platforms, plus half a day for the nice-to-have (§9).

---

## 1. Scope

### In scope
- Apple Music (`Music.app`) only.
- Discord presence settings modelled on Music Presence's main ones (§5.3).
- Last.fm: browser login, Now Playing, scrobbling with customisable rules (§6.3), offline queue.
- Menu bar UI, Settings window, launch at login.
- **Global hotkeys:** pause/resume scrobbling, pause/resume Discord presence (§7.1).
- *Nice-to-have:* a recent-scrobbles list in the menu (§6.4).

### Explicitly out of scope
- Other players (Spotify, browsers, TIDAL…), so no MediaRemote.
- The cover-art proxy server (we use public Apple artwork URLs instead, §5.2).
- Last.fm artist bios, similar artists, charts, full history browser, love/unlove.
- App Store distribution, sandboxing, auto-update, notarisation. It's your machine.

---

## 2. macOS primer for a web/infra engineer

Here's how the unfamiliar pieces map to things you already know.

| macOS concept | Web/infra analogy | Where it shows up |
|---|---|---|
| `.app` bundle | A deploy artifact: a directory holding the binary, a manifest and assets | What Xcode builds; you copy it to `/Applications` |
| `Info.plist` | `package.json` / manifest | App ID, "no Dock icon" flag, permission prompt strings, injected config |
| Entitlements | Capabilities / IAM policy embedded in the signature | Allows sending Apple Events under the hardened runtime |
| TCC (privacy prompts) | The browser's "allow notifications?" prompt, but OS-wide | "Apple Music Presence wants to control Music" (shown once) |
| Code signing identity | A TLS cert; TCC grants are tied to it | Keep it **stable**, or the permission resets on every rebuild (§10) |
| `DistributedNotificationCenter` | An OS-level pub/sub bus (Redis pub/sub between apps) | How Music.app announces track changes |
| Apple Events / ScriptingBridge | An RPC API into another app (AppleScript under the hood) | Asking Music for playhead position and artwork |
| SwiftUI | React: declarative views, re-rendered from state | Menu dropdown, Settings window |
| `@Observable` model | A MobX/Zustand store | `AppModel` holds the state the UI reads |
| `actor` | An object with its own single-threaded event loop; no locks needed | Discord client, scrobbler, queue |
| `UserDefaults` | `localStorage` | Non-secret settings |
| Keychain | Vault / a secret store | Last.fm session key |
| `SMAppService` | `systemctl enable` | Launch at login |
| `os.Logger` + Console.app | Structured logging + a log viewer | `log stream --predicate 'subsystem == "dev.dta32.applemusicpresence"'` |
| Instruments | pprof / Chrome DevTools memory tab | Checking the < 50 MB goal |

---

## 3. Architecture

```
                    ┌──────────────────────── Apple Music Presence.app (single process) ──────────────────────────┐
                    │                                                                                 │
 Music.app ──────── │─► MusicAppSource ──────► PlaybackEngine ─────(PlaybackEvent stream)──┬────────►│─► PresenceService ──► DiscordRPC (actor) ──► unix socket $TMPDIR/discord-ipc-N ──► Discord.app
  • distributed     │   (@MainActor)            (state machine,                             │         │        ▲
    notification    │   • observes             owns "what's playing                         │         │        │ artwork URL + Apple Music link
    com.apple.Music │     playerInfo            right now")                                 │         │   ArtworkResolver (actor) ──► itunes.apple.com/search (cached)
    .playerInfo     │   • polls position                                                    │         │
  • Apple Events ◄──│     every ~5s while                                                   └────────►│─► ScrobbleService ──► LastFMClient (actor) ──► ws.audioscrobbler.com/2.0
    (position,      │     playing                                                                     │        │
     artwork)       │                                                                                 │        └─► ScrobbleQueue (actor) ──► ~/Library/Application Support/AppleMusicPresence/queue.json
                    │                                                                                 │
                    │   AppModel (@Observable) ◄── reads everything ──► MenuBarExtra UI + Settings window
                    │   SettingsStore (UserDefaults, Codable)    Keychain (Last.fm session key)        │
                    └─────────────────────────────────────────────────────────────────────────────────┘
```

**Design rule:** `PlaybackEngine` is the only part that decides *what is happening*. It emits a small set of normalised events. Presence and scrobbling are two independent subscribers that never talk to each other, so either can be turned off or crash-loop without affecting the other.

```swift
enum PlaybackEvent {
    case started(Track, position: Duration, at: Date)     // new track, or the same track repeated
    case resumed(position: Duration, at: Date)
    case paused(position: Duration, at: Date)
    case seeked(to: Duration, at: Date)
    case stopped(at: Date)                                // Music quit / playback stopped / system sleep
}

struct Track: Hashable, Codable {
    let persistentID: String           // Music's stable ID; also used to detect repeats
    let title, artist: String
    let album, albumArtist: String?
    let duration: Duration?            // nil for radio/streams (never scrobbled)
    let trackNumber: Int?
    let genre: String?
    let year: Int?
    let storeURL: URL?                 // if Music provides one (verify in spike S1)
}
```

---

## 4. Getting "now playing" from Apple Music

### 4.1 Decision: distributed notification + Apple Events (not MediaRemote)

| Option | Verdict |
|---|---|
| **`com.apple.Music.playerInfo` distributed notification** | ✅ **Primary.** Music.app has always posted this (it dates back to iTunes). It's push-based and costs nothing while idle. The `userInfo` dict includes Name, Artist, Album, Total Time, Player State, PersistentID and others. |
| **Apple Events via ScriptingBridge** | ✅ **Secondary.** We need it for `player position` (the notification doesn't carry the playhead) and local artwork data for the menu UI. Requires a one-time "Allow Apple Music Presence to control Music" prompt. |
| MediaRemote private framework | ❌ Since macOS 15.4 it's blocked for third-party processes. Music Presence works around this by running `/usr/bin/perl` (Apple-entitled) with a helper framework, which is the 10.5 MB `perl` process above. We only need Apple Music, so we skip all that. |

### 4.2 Behaviour
- **Startup:** if Music is running, query its current state once, so a track that's already playing gets picked up.
- **On every notification:** read `Player State` and `PersistentID`, query `player position` and diff against the current session to produce `PlaybackEvent`s.
- **While playing:** poll `player position` every ~5 s using a timer with tolerance, so the OS can batch it with other work. If the position differs from where we expect it by more than 2 s, emit `.seeked`. If the same `PersistentID` jumps back near 0, emit `.started` (repeat-one). The poll stops while paused or stopped.
- **Music not running:** watch `NSWorkspace` launch/terminate notifications.
  > ⚠️ **Never send an Apple Event to Music unless it's already running.** `tell application "Music"` *launches* Music. Always check `NSRunningApplication` first.
- **Sleep/wake:** `NSWorkspace.willSleepNotification` → treat as `.paused`. On `didWake`, re-sync.
- **Radio/live streams** (no `Total Time`): show presence without a progress bar and never scrobble.

### 4.3 Things the spike must confirm on macOS 26.4 (§9, S1)
- The exact `userInfo` keys and value types, including whether `Store URL` is present and whether `Total Time` is in ms.
- Whether the notification fires on seek and on repeat-one. The plan assumes it doesn't and polls, which works either way.
- Whether ScriptingBridge or `NSAppleScript` is nicer from Swift 6. Default: a small ScriptingBridge `@objc` protocol for `playerPosition`, `playerState` and `currentTrack`, called on the main actor (each call takes about 1–5 ms).

---

## 5. Discord Rich Presence

### 5.1 How it works
The Discord desktop client listens on a Unix domain socket: `$TMPDIR/discord-ipc-0` … `discord-ipc-9`. We write a tiny client by hand, about 200 lines on `Network.framework` / POSIX sockets, with no dependencies:

```
frame   = opcode:UInt32 LE | length:UInt32 LE | JSON UTF-8 payload
opcodes = 0 HANDSHAKE · 1 FRAME · 2 CLOSE · 3 PING · 4 PONG

→ op0  {"v":1,"client_id":"<DISCORD_CLIENT_ID>"}
← op1  {"evt":"READY", ...}
→ op1  {"cmd":"SET_ACTIVITY","args":{"pid":<getpid()>,"activity":{...}},"nonce":"<uuid>"}
→ op1  {"cmd":"SET_ACTIVITY","args":{"pid":<getpid()>},"nonce":"<uuid>"}   // clears presence
```

Activity payload (fields per the current Activity object docs):

```jsonc
{
  "type": 2,                               // 2 = LISTENING → "Listening to {app name}"
  "status_display_type": 1,                // 0 = app name, 1 = state, 2 = details (member-list text)
  "details": "Song Title",                 "details_url": "https://music.apple.com/…",
  "state":   "Artist Name",                "state_url":   "https://music.apple.com/…artist",
  "timestamps": { "start": 1760400000000, "end": 1760400215000 },   // ms; both → progress bar
  "assets": {
    "large_image": "https://is1-ssl.mzstatic.com/…/600x600bb.jpg",  // external URLs allowed
    "large_text":  "Album Name",
    "small_image": "paused",                // optional, uploaded app asset
    "small_text":  "Paused"
  },
  "buttons": [ { "label": "Listen on Apple Music", "url": "https://music.apple.com/…" } ]
}
```

**Client rules** (in `DiscordRPC`, all unit tested):
- **Rate limit:** Discord allows 5 updates per 20 s. Use a leading+trailing throttle (at most one send every 4 s; the latest state wins). A burst of skips still settles on the correct track.
- **String limits:** `details`/`state`/`large_text` must be 2–128 chars. Truncate with `…`, and pad 1-char titles. Button labels: 1–32 chars, URL ≤ 512.
- **Reconnect:** if Discord isn't running, retry with backoff (5 s → 60 s cap). Also watch `NSWorkspace` for Discord launching, so the retry can fire immediately. On socket close, go back to that retry loop.
- Buttons are **not visible to yourself** on your own profile; others see them. Don't spend debugging time on this.

### 5.2 Album art without a proxy
Discord accepts external `https` image URLs in `large_image`. `ArtworkResolver` calls the **iTunes Search API** (`https://itunes.apple.com/search?term=<artist album>&entity=song&limit=5`), picks the best artist/title/album match, and rewrites `artworkUrl100` to `600x600bb`. The same result gives us the `music.apple.com` track/artist links for buttons and `*_url`. Results are cached in memory (LRU, about 200 entries) and on disk, keyed by `persistentID`.
Fallback for tracks not in the catalog (local files, uploads): an "Apple Music" logo asset uploaded to the Discord application.

### 5.3 Presence settings (modelled on Music Presence)

| Setting | Default | Notes |
|---|---|---|
| Enable presence | on | The master switch, in Settings |
| Pause presence | off | Temporary. Clears presence now and resumes when lifted. Scrobbling keeps running. Set from the menu bar (*for 1 h / until tomorrow / until I resume*) or the **hotkey** (§7.1). |
| Activity type | Listening | Listening / Playing |
| Member-list status shows | Artist | App name / Artist (state) / Title (details) → `status_display_type` |
| Details line template | `{title}` | Placeholders: `{title} {artist} {album} {albumArtist} {year} {genre} {trackNumber}` |
| State line template | `{artist}` | Same placeholders |
| Album art tooltip template | `{album}` | |
| Show album art | on | off → always the app logo |
| Show progress bar (timestamps) | on | |
| Clickable title/artist/cover links | on | `details_url`, `state_url`, `large_url` |
| Button 1 | Listen on Apple Music | Choose: none / Apple Music / Last.fm track page / song.link |
| Button 2 | none | Same options |
| **When playback is paused** | **Clear after delay, 30 s** | Picker: *Clear immediately* / *Clear after delay* (with a duration field, 5 s–60 min) / *Keep showing "Paused" indefinitely*. While shown, "Paused" uses the `paused` small icon, the details/state lines stay, and the progress bar is dropped. If playback resumes before the delay runs out, the cancelled clear never reaches Discord. |
| "Paused" small-icon text | `Paused` | Editable |
| Hide presence for | — | Ignore rules (artist/album/genre contains), shared with scrobbling (§6.3) |
| Discord Client ID override | (bundled) | Advanced. Changes what "Listening to ___" says (§7) |

The Settings tab includes a **live preview card** that renders the activity exactly as built from the current track and settings, so you can tune templates without switching to Discord.

---

## 6. Last.fm

### 6.1 Login: "just click Connect" (desktop auth flow)
1. `auth.getToken` (signed) → `token` (valid 60 min, single use).
2. Open the browser to `https://www.last.fm/api/auth/?api_key=…&token=…`.
3. Meanwhile, poll `auth.getSession(token)` every 2 s. It returns error 14 (*unauthorised token*) until you click **Allow**, then returns `{ name, key }`.
4. Save the session key in the **Keychain**. **It never expires** unless you revoke it on last.fm. Show "Connected as *username*" with a Disconnect button.

**Signing:** sort params by name → concatenate `name+value` → append the shared secret → MD5 (`CryptoKit.Insecure.MD5`) → hex. `format=json` is **excluded** from the signature (a common gotcha). Write methods are `POST` form-encoded to `https://ws.audioscrobbler.com/2.0/`.

### 6.2 Scrobble lifecycle
We count **actual listened time** (wall clock while state = playing), not playhead position. Seeking and scrubbing then can't game or break the threshold, and pausing for an hour doesn't count.

```
.started(track) ──► new PlaySession { track, startedAt, listened = 0 }
                    ├─ if eligible(track): send track.updateNowPlaying (fire-and-forget, never retried)
                    └─ schedule a threshold check
playing ticks   ──► listened += Δt
listened ≥ threshold && !submitted ──► (mode = at threshold) enqueue scrobble(timestamp = startedAt)
.started(next) / .stopped ──► (mode = at track end) enqueue if listened ≥ threshold; close session
```

```
threshold(track) = min( percent/100 × duration,  capEnabled ? cap : ∞ )
eligible(track)  = duration ≠ nil  &&  duration ≥ minTrackLength  &&  !ignored(track)
```

**`ScrobbleQueue`** (actor, persisted to `queue.json`; append-only and replayed in order):
- Flush in batches of ≤ 50 (`track.scrobble` with `artist[i]`, `track[i]`, `timestamp[i]`, `album[i]`, `albumArtist[i]`, `duration[i]`, `trackNumber[i]`).
- Retry with backoff on network errors and Last.fm errors 11/16. On error 9 (invalid session), mark the account disconnected and keep the queue. Drop on other errors (malformed) and log it.
- Each `ignored` code in the response (filtered artist, timestamp too old, daily limit…) is logged and shown in the menu as "1 scrobble ignored: timestamp too old".
- Flush triggers: on enqueue, on network-reachable (`NWPathMonitor`), on wake, on login.

### 6.3 Scrobble settings (the customisable part you asked for)

| Setting | Default | Range / notes |
|---|---|---|
| Enable scrobbling | on | The master switch, in Settings |
| Pause scrobbling | off | Temporary. Set from the menu bar (*for 1 h / until tomorrow / until I resume*) or the **hotkey** (§7.1). While paused, nothing is enqueued and Now Playing isn't sent. In *at threshold* mode, a track that already crossed its threshold before you paused was already enqueued, so it's still scrobbled. |
| Send Now Playing | on | |
| **Scrobble after** | **50 %** of track | Slider + numeric field, 1–100 % in 1 % steps |
| **…or after** (time cap) | **on, 4:00** | Toggle + duration field (0:30–20:00). Whichever comes first. |
| **Minimum track length** | **0:30** | 0:00–10:00. Tracks shorter than this are never scrobbled. |
| **Submit timing** | **At threshold** | Picker: *At threshold*: enqueued the moment listened time crosses it, so quitting or a crash mid-track doesn't lose it. *When track ends or is skipped*: decided at the end, so skipping or **pausing scrobbling** before the track ends drops it. The scrobble timestamp is the track's start time either way. |
| Scrobble repeats | on | Repeat-one / replaying the same track counts again |
| Ignore rules | none | List of `{field: artist/album/title/genre, op: contains/equals/regex}`, shared with presence |
| Metadata | Send album artist | Toggle whether `albumArtist` is sent |

> Note: Last.fm's published rule is "longer than 30 s, and half the track or 4 minutes". The API accepts scrobbles that don't follow it, so with these settings the rule is yours to set. The defaults match the official rule exactly.

### 6.4 Recent scrobbles (nice-to-have, P6)
- A `ScrobbleHistory` actor keeps the last **50** entries in `history.json`, next to the queue: `{track, timestamp, status}`, where status is `queued` → `sent` / `ignored(reason)` / `failed(reason)`. It's a fixed-size ring and never grows.
- The menu gets a collapsible "Recent" section: the last ~10, each with a status glyph (⏳ queued, ✓ sent, ⚠︎ ignored + reason on hover). Clicking an entry opens it on last.fm.
- Read straight from our own history; no Last.fm API call (`user.getRecentTracks` would be a second source of truth and cost a network round trip on every menu open).

---

## 7. One-time setup and configuration

**You do these once as the developer (~10 min total, documented in the README):**
1. **Discord:** create an application at discord.com/developers → name it **"Apple Music"**. That name is what shows in "Listening to ___". Upload two Rich Presence art assets: `logo` (Apple Music icon, fallback cover) and `paused`. Copy the **Application ID**. No bot, no token, no OAuth, no redirect URL.
2. **Last.fm:** create an API account at last.fm/api/account/create and copy the **API key** and **shared secret**. The callback URL can be blank because we use the desktop flow.
3. Put them in `Config/Secrets.xcconfig` (gitignored, with a `Secrets.xcconfig.example` committed). Xcode injects them into `Info.plist`, and the app reads them via `Bundle.main`. Embedding an API secret in a desktop client is normal practice; the official scrobbler does the same.

**As the app user:** launch → allow "control Music" once → click **Connect Last.fm** → done. Discord connects by itself whenever Discord is running.

**Settings storage:** one `Codable` `Settings` struct in `UserDefaults` (a single JSON blob, versioned for migrations). Add **Export/Import settings (JSON)** in Advanced. That's cheap, and it gives you a "dotfile" you can keep in git.

### 7.1 Global hotkeys

| Action | Default | Behaviour |
|---|---|---|
| Toggle **pause scrobbling** | ⌃⌥⌘S | Not paused → paused *until I resume*. Paused (any duration) → resumed. |
| Toggle **pause Discord presence** | ⌃⌥⌘D | Same, for presence. Clears it immediately; resuming re-sends the current track straight away. |

- **Mechanism:** Carbon `RegisterEventHotKey`. It's old but still the supported way to register system-wide shortcuts, and it needs **no Accessibility / Input Monitoring permission**. A global `NSEvent` monitor or `CGEventTap` would need those permissions. It's about 80 lines in `Support/HotKeys.swift`.
- **Rebindable** in Settings → General, using a small shortcut-recorder field (click, press the combo, done; ⌫ clears it). It's written by hand to keep zero dependencies. The fallback, if the recorder turns into a time sink, is [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), which would be the only dependency.
- **Rules:** since macOS 15, shortcuts whose only modifiers are ⌥ or ⌥⇧ are rejected, so the recorder requires ⌘ or ⌃. If registration fails because another app owns the combo, Settings says so instead of failing silently.
- **Feedback** (you won't be looking at the menu when you press it): the menu bar icon changes state (normal / scrobbling paused / presence paused / both). An optional banner ("Scrobbling paused") is off by default, and enabling it triggers the macOS notification permission prompt.

---

## 8. Project layout and tech choices

```
~/code/apple-music-presence/
├── README.md                      # human-facing: setup, build, install, the one-time steps of §7
├── CLAUDE.md                      # agent-facing conventions
├── AppleMusicPresence.xcodeproj
├── Config/
│   ├── Secrets.xcconfig.example
│   └── Secrets.xcconfig           # gitignored
├── AppleMusicPresence/                       # app target: macOS-specific glue + UI only
│   ├── AppleMusicPresenceApp.swift           # @main · MenuBarExtra(.window style) + Settings scene
│   ├── AppModel.swift             # @Observable; wires engine → services; exposes UI state
│   ├── Music/MusicAppSource.swift # distributed notifications + ScriptingBridge + NSWorkspace
│   ├── UI/MenuContentView.swift   # now-playing card, Discord/Last.fm status, pause menus, queue count, recent
│   ├── UI/Settings/{General,Discord,LastFM,Advanced}View.swift
│   ├── UI/{PresencePreview,ShortcutRecorder}.swift
│   ├── Support/{Keychain,LaunchAtLogin,HotKeys,Log}.swift
│   ├── Info.plist                 # LSUIElement=YES, NSAppleEventsUsageDescription, injected IDs
│   └── AppleMusicPresence.entitlements       # hardened runtime + com.apple.security.automation.apple-events
└── Packages/AMPKit/           # pure Swift, no AppKit; `swift test` works from the terminal
    ├── Package.swift
    ├── Sources/
    │   ├── AMPCore/           # Track, PlaybackEvent, PlaybackEngine, PlaySession, ScrobbleRules,
    │   │                          #   Template renderer, IgnoreRules, Settings model, Clock protocol
    │   ├── DiscordRPC/            # frame codec, IPC connection, DiscordClient actor, Activity model, throttle
    │   ├── LastFM/                # Signer, LastFMClient actor, AuthFlow, ScrobbleQueue + ScrobbleHistory actors
    │   └── Artwork/               # iTunes Search client, matcher, cache
    └── Tests/                     # Swift Testing (`import Testing`)
```

| Choice | Why |
|---|---|
| **Min macOS 26** | Your machine only. Gets `@Observable`, `MenuBarExtra`, `SMAppService`, `SettingsLink`, and Swift Testing without availability checks. |
| **Swift 6 language mode, strict concurrency** | Data races become compile errors. Actors replace locks. |
| **Zero third-party dependencies** | Discord IPC, Last.fm and iTunes Search are each a few hundred lines. Fewer deps, smaller footprint, nothing to audit. |
| **Not sandboxed** | The sandbox would move `$TMPDIR` into a container, so we'd never find Discord's socket. It also complicates Apple Events. Hardened runtime stays on. |
| **Signing: "Apple Development" with your free Personal Team** | Gives a stable identity, so the "control Music" grant and the Keychain item survive rebuilds. Ad-hoc signing changes identity every build → the prompt comes back every time. |
| **Testable time:** inject a `Clock` into `PlaybackEngine`/`PlaySession` | Scrobble-rule tests run in microseconds and are deterministic. |
| **Install:** `make install` → `xcodebuild -scheme AppleMusicPresence -configuration Release` + copy to `/Applications` | Lets you deploy from the terminal. |

---

## 9. Milestones

Each phase ends with something you can run. Estimates assume you're learning as you go.

| # | Phase | Deliverable / exit criteria | Est. |
|---|---|---|---|
| **P0** | **Setup + 3 spikes** (throwaway, de-risk the unknowns) | Xcode installed; Personal Team signing works. Project created at `~/code/apple-music-presence`, **local `git init` only** (no remote). The `.gitignore` covers `xcuserdata/`, `DerivedData/`, `.build/`, `Config/Secrets.xcconfig` and `.DS_Store`. Spikes live in `spikes/` and are deleted after P1. **S1:** a console app logs every `playerInfo` notification + `player position` while you play/pause/seek/skip/repeat → record the real keys in the README. **S2:** a 50-line script sets a hardcoded "Listening to Apple Music" presence over the socket. **S3:** desktop auth → session key → `updateNowPlaying` succeeds. | 1 d |
| **P1** | Skeleton + Music source | Menu bar app (no Dock icon) shows the current track, artwork and state live. `PlaybackEngine` emits correct events (unit tests for repeat/seek/stop). Doesn't launch Music by accident. | 1 d |
| **P2** | Discord presence | Presence follows playback with a progress bar and album art (iTunes lookup + cache). Throttle and reconnect tested. Survives quitting and relaunching Discord. | 1 d |
| **P3** | Last.fm | Connect/disconnect, Now Playing, scrobbling with the default rules, persistent queue, offline → online flush. Rule matrix unit-tested. | 1.5 d |
| **P4** | Settings + config + hotkeys | All settings from §5.3/§6.3 plus the live preview, templates, ignore rules, launch at login, export/import. Both pause menus, the global hotkeys with the recorder, and the menu bar icon states (§7.1). | 2 d |
| **P5** | Hardening + cutover | Sleep/wake, network loss, Music quit mid-track, a soak test of 3+ days with `footprint -p` sampled hourly (it must stay flat). Instruments Leaks/Allocations show no leaks. Idle footprint < 50 MB. Then **let the official Last.fm app flush its cache**, quit and uninstall both old apps. | 1 d |
| *P6* | *Nice-to-have: recent scrobbles* | `ScrobbleHistory` + the "Recent" menu section (§6.4). Can ship any time after P3. | 0.5 d |

---

## 10. Gotchas and risks

| Risk | Mitigation |
|---|---|
| Apple Event to Music **launches Music** | Always check `NSRunningApplication` first (§4.2). |
| TCC prompt reappears after every rebuild | Stable "Apple Development" signing (§8). If it gets wedged: `tccutil reset AppleEvents dev.dta32.applemusicpresence`. |
| `playerInfo` keys differ from what's documented online / change in a future macOS | S1 records the real keys. Parsing is defensive (optional fields), and missing data degrades the feature instead of crashing. Apple Events are the fallback source. |
| Discord rate limit (5 per 20 s) during rapid skipping | Leading+trailing throttle; the latest state wins. |
| iTunes Search returns the wrong album art | Strict matching (normalised artist + album), fall back to the logo instead of guessing. Cache misses for 24 h too. |
| Double scrobbles while migrating | Run Apple Music Presence with scrobbling **off** alongside the old app until P5. Flip it on only after uninstalling the official scrobbler. |
| Memory creep from artwork | Downsample artwork to menu size before holding it. Keep only the current one in memory. LRU caches stay small. |
| Last.fm "timestamp too old" for long offline periods | Surface the ignored count in the menu. Nothing else to do; it's a server rule. |
| Swift 6 strict-concurrency errors feel hostile at first | Keep AppKit/ScriptingBridge on `@MainActor` and networking in actors. Don't fight it with `@unchecked Sendable`. |

---

## 11. Testing strategy

- **Unit (Swift Testing, `swift test` in `Packages/AMPKit`):** scrobble threshold matrix (percent × cap × min length × submit timing × pause/seek/repeat sequences, using a fake clock); Discord frame encode/decode, string truncation/padding, throttle behaviour; Last.fm signature against a known test vector, `format` excluded; queue persistence round-trip and retry classification; template rendering; iTunes match scoring; pause-presence delay cancel-on-resume; pause-scrobbling × submit-timing interaction; history ring stays capped at 50.
- **Manual checklist (README):** play/pause/skip/seek/repeat-one/shuffle; Music quit mid-track; Discord quit/relaunch; Wi-Fi off for 10 min, then on; sleep the lid mid-track; radio station; a local file not in the catalog; a track under 30 s; both hotkeys while another app is focused; a hotkey combo already taken by another app.
- No UI tests. Not worth it for a personal app.

---

## 12. Decisions log

| # | Question | Decision (Radit, 2026-10-14) |
|---|---|---|
| 1 | App name | Generic **"Apple Music Presence"** for now. Bundle ID `dev.dta32.applemusicpresence`, repo `~/code/apple-music-presence`. |
| 2 | "Listening to ___" label | Discord application named **"Apple Music"** |
| 3 | Presence behaviour while paused | **User-controllable**: clear immediately / clear after delay (default 30 s) / keep "Paused" indefinitely (§5.3) |
| 4 | Scrobble submit timing | **User-controllable**: at threshold (default) / when track ends or is skipped (§6.3) |
| 5 | Extras | No love/unlove. **Hotkeys** for pause scrobbling + pause presence (§7.1). Recent scrobbles = nice-to-have (§6.4, P6). |
| 6 | Repo | **Local `git init` only**, no remote |
| — | Toolchain | **Xcode** + local Swift package for logic |

---

## 13. Implementation notes (2026-10-14)

Spike S1, run on macOS 26.4.1:

- `com.apple.Music.playerInfo` carries only: Album, Artist, Composer, Genre, Library PersistentID, Name, PersistentID (signed Int64), Player State, Total Time (ms). **No** Album Artist, Track Number, Year or Store URL, so AppleScript is the metadata source and the notification is just a trigger.
- Play and pause each produce **two** notifications ~20–100 ms apart (e.g. Paused→Playing). Debounced 150 ms.
- **Seeking produces no notification.** Polling every 5 s while playing is required.
- Discord IPC socket at `$TMPDIR/discord-ipc-0`. Handshake with an invalid client ID → `CLOSE` with code 4000 "Invalid Client ID" (verified live).

Deviations from the plan:

- Repo at `~/code/apple-music-presence`; bundle ID `dev.dta32.applemusicpresence`.
- AppleScript is read via `NSAppleScript` (not ScriptingBridge); the result parser lives in AMPCore so it's unit-tested.
- Recent-scrobbles history (P6) shipped with the first version since it was small.
- Scrobbling is treated as paused while no Last.fm account is connected, so a queue can't build up that might never be sent.
- First measured idle footprint: **17–18 MB** (peak 29 MB).
