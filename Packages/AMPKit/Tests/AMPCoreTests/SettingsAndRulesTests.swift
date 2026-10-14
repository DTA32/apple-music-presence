import AMPCore
import Foundation
import Testing

@Suite struct SettingsCodecTests {
    @Test func roundTrip() throws {
        var settings = AppSettings()
        settings.scrobbling.thresholdPercent = 35
        settings.presence.pausedBehavior = .keepShowing
        settings.ignoreRules = [IgnoreRule(field: .genre, match: .equals, value: "Podcast")]
        settings.hotkeys.togglePresence = nil
        #expect(try SettingsCodec.decode(SettingsCodec.encode(settings)) == settings)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        // As if saved by an older build that only knew two fields.
        let old = #"{"version":1,"scrobbling":{"thresholdPercent":70},"presence":{"pausedText":"zzz"}}"#
        let settings = try SettingsCodec.decode(Data(old.utf8))
        #expect(settings.scrobbling.thresholdPercent == 70)
        #expect(settings.scrobbling.capSeconds == 240)
        #expect(settings.presence.pausedText == "zzz")
        #expect(settings.presence.detailsTemplate == "{title}")
        #expect(settings.hotkeys.toggleScrobbling == .defaultToggleScrobbling)
    }
}

@Suite struct TemplateTests {
    let track = Track(persistentID: "A", title: "Love Me Like a Friend", artist: "Fly By Midnight", album: "Happy About Everything Else...", duration: 202, genre: "Pop", year: 2017)

    @Test func rendersPlaceholders() {
        #expect(Template.render("{title}", track: track) == "Love Me Like a Friend")
        #expect(Template.render("by {artist} ({year})", track: track) == "by Fly By Midnight (2017)")
        #expect(Template.render("{albumArtist}", track: track) == "Fly By Midnight") // falls back to artist
    }

    @Test func missingValuesLeaveNoDanglingSeparators() {
        var noAlbum = track
        noAlbum.album = nil
        #expect(Template.render("{title} · {album}", track: noAlbum) == "Love Me Like a Friend")
        #expect(Template.render("{trackNumber} - {title}", track: noAlbum) == "Love Me Like a Friend")
    }

    @Test func unknownPlaceholdersKeptVerbatim() {
        #expect(Template.render("{title} {nope}", track: track) == "Love Me Like a Friend {nope}")
    }
}

@Suite struct IgnoreRuleTests {
    let track = Track(persistentID: "A", title: "Intro (Live)", artist: "Beyoncé", album: "Homecoming", genre: "R&B/Soul")

    @Test func matching() {
        #expect(IgnoreRule(field: .artist, match: .contains, value: "beyonce").matches(track))
        #expect(IgnoreRule(field: .artist, match: .equals, value: "BEYONCÉ").matches(track))
        #expect(!IgnoreRule(field: .artist, match: .equals, value: "Bey").matches(track))
        #expect(IgnoreRule(field: .title, match: .regex, value: #"\(live\)$"#).matches(track))
        #expect(!IgnoreRule(field: .title, match: .regex, value: "([").matches(track)) // invalid regex never matches
        #expect(!IgnoreRule(field: .genre, match: .contains, value: "").matches(track))
    }

    @Test func scopes() {
        let rules = [IgnoreRule(field: .genre, match: .contains, value: "soul", scope: .scrobbling)]
        #expect(rules.ignores(track, for: .scrobbling))
        #expect(!rules.ignores(track, for: .presence))
    }
}

@Suite struct PauseStateTests {
    @Test func expiry() {
        let now = t0
        #expect(!PauseState.active.isPaused(at: now))
        #expect(PauseState.paused(until: nil).isPaused(at: now))
        #expect(PauseState.paused(until: now.addingTimeInterval(60)).isPaused(at: now))
        #expect(!PauseState.paused(until: now).isPaused(at: now))
    }

    @Test func tomorrowIsNextMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        let tomorrow = PauseState.tomorrow(after: t0, calendar: calendar)
        #expect(tomorrow > t0)
        #expect(calendar.component(.hour, from: tomorrow) == 0)
        #expect(tomorrow.timeIntervalSince(t0) <= 86_400)
    }

    @Test func hotkeyComboSystemRule() {
        #expect(KeyCombo.defaultToggleScrobbling.isAllowedBySystem)
        #expect(!KeyCombo(keyCode: 1, carbonModifiers: KeyCombo.option | KeyCombo.shift, display: "⌥⇧S").isAllowedBySystem)
    }
}
