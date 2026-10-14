import AMPCore
@testable import AMPPresence
import DiscordRPC
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_760_000_000)
private let track = Track(persistentID: "A", title: "Love Me Like a Friend", artist: "Fly By Midnight", album: "Happy About Everything Else...", duration: 200)
private let artwork = ArtworkInfo(
    artworkURL: URL(string: "https://img.example/600x600bb.jpg"),
    trackURL: URL(string: "https://music.apple.com/us/album/x/1?i=2"),
    artistURL: URL(string: "https://music.apple.com/us/artist/a/3"),
    albumURL: URL(string: "https://music.apple.com/us/album/x/1")
)

private func input(_ state: PlayerState = .playing, position: TimeInterval = 50, pausedSince: Date? = nil, paused: Bool = false, ignored: Bool = false, art: ArtworkInfo? = artwork) -> PresenceInput {
    PresenceInput(track: track, state: state, position: position, positionDate: now, pausedSince: pausedSince, artwork: art, isPresencePaused: paused, isIgnored: ignored)
}

private func activity(_ decision: PresenceDecision) -> Activity? {
    switch decision {
    case .clear: nil
    case .show(let a), .showUntil(let a, _): a
    }
}

@Suite struct PresenceBuilderTests {
    @Test func playingDefaults() throws {
        let a = try #require(activity(PresenceBuilder.decide(input(), settings: PresenceSettings(), now: now)))
        #expect(a.type == 2)
        #expect(a.statusDisplayType == 1)
        #expect(a.details == "Love Me Like a Friend")
        #expect(a.state == "Fly By Midnight")
        #expect(a.timestamps?.start == Int64(1_759_999_950_000))
        #expect(a.timestamps?.end == Int64(1_760_000_150_000))
        #expect(a.assets?.largeImage == "https://img.example/600x600bb.jpg")
        #expect(a.assets?.largeText == "Happy About Everything Else...")
        #expect(a.assets?.smallImage == nil)
        #expect(a.detailsURL == "https://music.apple.com/us/album/x/1?i=2")
        #expect(a.buttons == [.init(label: "Listen on Apple Music", url: "https://music.apple.com/us/album/x/1?i=2")])
    }

    @Test func clearsWhenDisabledPausedIgnoredOrStopped() {
        var disabled = PresenceSettings()
        disabled.enabled = false
        #expect(PresenceBuilder.decide(input(), settings: disabled, now: now) == .clear)
        #expect(PresenceBuilder.decide(input(paused: true), settings: PresenceSettings(), now: now) == .clear)
        #expect(PresenceBuilder.decide(input(ignored: true), settings: PresenceSettings(), now: now) == .clear)
        #expect(PresenceBuilder.decide(input(.stopped), settings: PresenceSettings(), now: now) == .clear)
    }

    @Test(arguments: [
        (PausedBehavior.clearImmediately, 0.0, "clear"),
        (PausedBehavior.keepShowing, 3600.0, "show"),
        (PausedBehavior.clearAfterDelay, 10.0, "showUntil"),
        (PausedBehavior.clearAfterDelay, 31.0, "clear"),
    ])
    func pausedBehaviour(behavior: PausedBehavior, pausedFor: Double, expected: String) {
        var settings = PresenceSettings()
        settings.pausedBehavior = behavior
        settings.pausedClearDelay = 30
        let decision = PresenceBuilder.decide(input(.paused, pausedSince: now.addingTimeInterval(-pausedFor)), settings: settings, now: now)
        switch decision {
        case .clear: #expect(expected == "clear")
        case .show(let a):
            #expect(expected == "show")
            #expect(a.timestamps == nil)
            #expect(a.assets?.smallImage == "paused")
            #expect(a.assets?.smallText == "Paused")
        case .showUntil(_, let until):
            #expect(expected == "showUntil")
            #expect(until == now.addingTimeInterval(20))
        }
    }

    @Test func customTemplatesAndToggles() throws {
        var settings = PresenceSettings()
        settings.detailsTemplate = "{artist} — {title}"
        settings.stateTemplate = "on {album}"
        settings.showArtwork = false
        settings.showProgress = false
        settings.clickableLinks = false
        settings.statusDisplay = .details
        settings.activityType = .playing
        settings.button1 = .lastFM
        settings.button2 = .appleMusic
        let a = try #require(activity(PresenceBuilder.decide(input(), settings: settings, now: now)))
        #expect(a.details == "Fly By Midnight — Love Me Like a Friend")
        #expect(a.state == "on Happy About Everything Else...")
        #expect(a.assets?.largeImage == "logo")
        #expect(a.timestamps == nil)
        #expect(a.detailsURL == nil)
        #expect(a.type == 0)
        #expect(a.statusDisplayType == 2)
        #expect(a.buttons?.map(\.label) == ["View on Last.fm", "Listen on Apple Music"])
        #expect(a.buttons?.first?.url == "https://www.last.fm/music/Fly+By+Midnight/_/Love+Me+Like+a+Friend")
    }

    @Test func withoutCatalogMatchFallsBackToLogoAndSearch() throws {
        let a = try #require(activity(PresenceBuilder.decide(input(art: nil), settings: PresenceSettings(), now: now)))
        #expect(a.assets?.largeImage == "logo")
        #expect(a.buttons?.first?.label == "Search on Apple Music")
        #expect(a.buttons?.first?.url.hasPrefix("https://music.apple.com/search?term=") == true)
    }
}
