# Apple Music Presence

A native macOS menu bar app that watches **Apple Music** and:

- shows what you're playing as **Discord Rich Presence** ("Listening to Apple Music", with cover art, progress bar and buttons), and
- **scrobbles to Last.fm**, with your own rules for when a play counts.

It replaces two apps: the official Last.fm Scrobbler (Intel-only, runs under Rosetta, ~900 MB after a few weeks) and Music Presence (~100 MB + a helper process). This app idles at about **18 MB**.

Swift 6 + SwiftUI, macOS 26+, Apple Music only, no third-party dependencies.

---

## One-time setup

You need three values from two developer portals, plus (recommended) a free signing identity. About 10 minutes.

### 1. Discord application (gives the "Listening to **Apple Music**" name)

1. Go to <https://discord.com/developers/applications> → **New Application** → name it **`Apple Music`**.
   That name is exactly what Discord shows after "Listening to".
2. **Rich Presence → Art Assets** → upload the two images in [`Assets/discord/`](Assets/discord):
   - `logo.png` with the key **`logo`** (fallback cover when a track isn't in the Apple Music catalogue)
   - `paused.png` with the key **`paused`** (badge shown while paused, if you choose to keep showing paused tracks)

   Re-generate them any time with `swift scripts/make-discord-assets.swift Assets/discord`.
3. **General Information** → copy the **Application ID**.

No bot, token, OAuth or redirect URL is needed. The app talks to the Discord desktop client locally.

### 2. Last.fm API account

1. Go to <https://www.last.fm/api/account/create>. Name/description can be anything; callback URL can stay empty.
2. Copy the **API key** and **Shared secret**.

### 3. Put them in `Config/Secrets.xcconfig`

```sh
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
```

```
DISCORD_CLIENT_ID = 123456789012345678
LASTFM_API_KEY = abc...
LASTFM_SHARED_SECRET = def...
```

This file is gitignored. The values are compiled into the app's Info.plist.

### 4. Stable signing (recommended)

Out of the box the app is signed ad-hoc, so it builds on any Mac. The catch is that each rebuild gets a new identity. macOS may then ask again for the "control Music" permission, and the Keychain may ask before handing over the Last.fm session.

To avoid that, use your free Personal Team:

1. Xcode → **Settings → Accounts** → **+** → Apple ID.
2. Click **Manage Certificates…** → **+** → **Apple Development**.
3. Check it's usable: `security find-identity -v -p codesigning` should list it as valid. If it says `0 valid identities found`, the Apple WWDR G3 intermediate certificate is missing (older Macs only have the G1 that expired in 2023). Install it:
   ```sh
   curl -fsSLO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
   security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
   ```
4. Find your **team ID**. It's the certificate's `OU` field, **not** the code in parentheses in the certificate name (for Personal Teams they differ):
   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```
5. Uncomment the signing lines at the bottom of `Config/Secrets.xcconfig`, keeping `CODE_SIGN_STYLE = Manual` (the app needs no provisioning profile).

After the first signed build, macOS asks once more for "control Music" and the Keychain may ask once about the Last.fm session (click **Always Allow**). From then on, rebuilds keep both.

---

## Build and run

```sh
make run        # Debug build, launch it (menu bar icon: ♪)
make install    # Release build → /Applications, launch it
make test       # unit tests for the logic package (no Xcode UI needed)
make logs       # stream the app's logs
make footprint  # memory as Activity Monitor reports it
```

Or open `AppleMusicPresence.xcodeproj` in Xcode and press ⌘R.

On first launch macOS asks **"Apple Music Presence wants to control Music"**. Click **Allow**. If you clicked Don't Allow, use the menu's *Open Automation Settings* button, or reset it with `tccutil reset AppleEvents dev.dta32.applemusicpresence`.

Then open **Settings… → Last.fm → Connect Last.fm…**, click **Yes, allow access** in the browser, and you're done. Discord connects by itself whenever Discord is running.

To start at login: **Settings → General → Launch at login** (works best from `/Applications`, i.e. after `make install`).

### Switching from the old apps

1. Keep **Scrobble to Last.fm** off in this app while the official Last.fm app is still running, otherwise you get double scrobbles.
2. Let the official app flush its queue (its menu shows pending scrobbles), quit it, uninstall it.
3. Quit Music Presence (and remove it from Login Items).
4. Turn scrobbling on here.

---

## What you can configure

| Area | Settings |
|---|---|
| **Discord** | on/off · activity type (Listening/Playing) · what the member list shows (app name / artist / title) · text templates for both lines and the cover tooltip (`{title} {artist} {album} {albumArtist} {year} {genre} {trackNumber} {composer}`) · album art · progress bar · clickable title/artist/cover · two buttons (Apple Music / Last.fm / none) · **when paused**: clear immediately, clear after a delay, or keep showing "Paused" · live preview |
| **Last.fm** | on/off · Now Playing · **threshold %** (1–100) · optional **time cap** ("or after N minutes, whichever first") · **minimum track length** · **submit timing**: as soon as the threshold is reached, or when the track ends/is skipped · repeats · album artist · queue status |
| **Filters** | ignore by artist/album/title/genre (contains / is / regex), for Discord, Last.fm or both |
| **General** | launch at login · global shortcuts: **⌃⌥⌘S** pause/resume scrobbling, **⌃⌥⌘D** pause/resume Discord presence (rebindable) · optional notification on toggle |
| **Advanced** | Discord client ID override · export/import settings as JSON · data folder |

The defaults match Last.fm's official rule: tracks longer than 30 s, scrobbled after half the track or 4 minutes. Only **time actually listened** counts: seeking ahead doesn't count, and time spent paused doesn't either.

The menu also offers **Pause → for 1 hour / until tomorrow / until I resume** for each service. The menu bar icon changes while something is paused: `pause.circle` = scrobbling paused, `eye.slash` = presence paused, filled = both.

---

## How it works

```
Music.app ──"com.apple.Music.playerInfo" notification──┐
          ◄── AppleScript: state, position, metadata ──┤  MusicAppSource  (debounced; polls every 5 s only while playing)
                                                       ▼
                                                PlaybackEngine   snapshots → started / resumed / paused / seeked / stopped
                                                       │
                     ┌─────────────────────────────────┴───────────────────────────┐
                     ▼                                                             ▼
   PresenceBuilder + ArtworkResolver (iTunes Search API)              ScrobbleTracker (listened time, thresholds)
                     ▼                                                             ▼
   DiscordIPCClient → $TMPDIR/discord-ipc-0 (Discord desktop)        ScrobbleSubmitter → queue.json → Last.fm API
```

- **Why not MediaRemote?** Since macOS 15.4 it's blocked for third-party apps. Music Presence works around it with a `perl` helper process. We only need Apple Music, which announces its own changes.
- **Seeks and repeat-one** don't trigger Music's notification, so the playhead is polled every 5 s while playing (never while paused).
- **Discord IPC** is a local Unix socket with a tiny framing protocol, written by hand (~300 lines). Updates are throttled to stay under Discord's 5-per-20-seconds limit.
- **Cover art** comes from the public iTunes Search API, matched strictly by artist + title (falls back to the `logo` asset rather than showing a wrong cover). Cached on disk.
- **Scrobbles** are persisted before sending and retried with backoff, so quitting, sleeping or going offline doesn't lose them. Last.fm drops scrobbles older than ~2 weeks.

### Layout

```
AppleMusicPresence/        app target: Music.app glue, coordinator (AppModel), SwiftUI views
Packages/AMPKit/           all testable logic, `swift test` from the terminal
  AMPCore/                 Track, PlaybackEngine, ScrobbleTracker, settings, templates, filters
  DiscordRPC/              IPC framing, socket, client actor, throttle
  LastFM/                  signing, API client, queue, submitter, history
  Artwork/                 iTunes Search matching + cache
  AMPPresence/             playback state + settings → Discord activity
Config/                    xcconfig, Info.plist, entitlements
Assets/discord/            images to upload to the Discord application
Assets/app-icon-source.png app icon artwork → `swift scripts/make-app-icon.swift Assets/app-icon-source.png AppleMusicPresence/Assets.xcassets/AppIcon.appiconset`
docs/PLAN.md               the original implementation plan
```

Data lives in `~/Library/Application Support/AppleMusicPresence/` (queue, recent history, artwork cache). Settings are in `UserDefaults` (`dev.dta32.applemusicpresence`). The Last.fm session key is in the login Keychain.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu says "Allow control of Music" | System Settings › Privacy & Security › Automation → enable *Apple Music Presence → Music*. Or `tccutil reset AppleEvents dev.dta32.applemusicpresence` and relaunch. |
| Discord: "Waiting for Discord…" | Discord desktop must be running (the web client has no IPC). It reconnects automatically within a minute, immediately when Discord launches. |
| Discord: "Invalid Client ID (4000)" | `DISCORD_CLIENT_ID` is wrong. Fix `Config/Secrets.xcconfig` and rebuild, or set the override in Settings → Advanced. |
| Buttons don't show on my profile | Discord hides activity buttons from yourself. Others see them. |
| Cover shows the generic logo | The track isn't in the Apple Music catalogue (local file / upload), or the match wasn't confident enough. |
| "1 scrobble ignored: Timestamp too old" | Last.fm rejects scrobbles older than about two weeks. |
| Keychain asks for permission after each rebuild | Ad-hoc signing. Set up stable signing (step 4). |
| Build error: `No signing certificate "Mac Development" found … team ID` | `DEVELOPMENT_TEAM` is wrong. Use the certificate's OU, not the code in its name (step 4). |

Live checks against the real Discord app and iTunes Search API: `make test-live`. Add `AMP_DISCORD_CLIENT_ID=<id>` to also show a test presence for 10 s.
