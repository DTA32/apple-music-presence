import AMPCore
import Foundation
import Testing

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func context(_ configure: (inout ScrobbleSettings) -> Void = { _ in }, paused: Bool = false, ignored: Bool = false) -> ScrobbleTracker.Context {
    var settings = ScrobbleSettings()
    configure(&settings)
    return .init(settings: settings, isPaused: paused, isIgnored: { _ in ignored })
}

private func scrobbles(_ actions: [ScrobbleAction]) -> [Scrobble] {
    actions.compactMap { if case .scrobble(let s) = $0 { s } else { nil } }
}

@Suite struct ScrobbleThresholdTests {
    @Test(arguments: [
        // (percent, capEnabled, cap, duration, expected threshold)
        (50.0, true, 240.0, 200.0, 100.0),
        (50.0, true, 240.0, 600.0, 240.0),   // 4-minute cap wins on long tracks
        (50.0, false, 240.0, 600.0, 300.0),
        (30.0, true, 240.0, 200.0, 60.0),
        (100.0, false, 0.0, 200.0, 200.0),
        (0.0, false, 0.0, 200.0, 2.0),       // clamped to 1%
    ])
    func threshold(percent: Double, capEnabled: Bool, cap: Double, duration: Double, expected: Double) {
        var settings = ScrobbleSettings()
        settings.thresholdPercent = percent
        settings.capEnabled = capEnabled
        settings.capSeconds = cap
        #expect(settings.threshold(forDuration: duration) == expected)
    }

    @Test func minimumLength() {
        var settings = ScrobbleSettings()
        #expect(!settings.isLongEnough(makeTrack(duration: 29)))
        #expect(settings.isLongEnough(makeTrack(duration: 30)))
        #expect(!settings.isLongEnough(makeTrack(duration: nil)))
        settings.minTrackLength = 0
        #expect(settings.isLongEnough(makeTrack(duration: 5)))
    }
}

@Suite struct ScrobbleTrackerTests {
    let track = makeTrack(duration: 200) // threshold 100 s by default

    @Test func nowPlayingThenScrobbleAtThreshold() {
        var tracker = ScrobbleTracker()
        let ctx = context()
        #expect(tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: ctx) == [.nowPlaying(track)])
        #expect(tracker.nextDecisionDate(context: ctx) == at(100))
        #expect(tracker.tick(at: at(99), context: ctx).isEmpty)
        let result = scrobbles(tracker.tick(at: at(100), context: ctx))
        #expect(result.count == 1)
        #expect(result.first?.timestamp == at(0))
        // Decided once: no duplicate at track end.
        #expect(tracker.handle(.stopped(at: at(200)), context: ctx).isEmpty)
    }

    @Test func pausedTimeDoesNotCount() {
        var tracker = ScrobbleTracker()
        let ctx = context()
        _ = tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: ctx)
        _ = tracker.handle(.paused(position: 60, at: at(60)), context: ctx)
        #expect(tracker.nextDecisionDate(context: ctx) == nil)
        _ = tracker.handle(.resumed(position: 60, at: at(1000)), context: ctx)
        #expect(tracker.nextDecisionDate(context: ctx) == at(1040))
        #expect(tracker.tick(at: at(1039), context: ctx).isEmpty)
        #expect(scrobbles(tracker.tick(at: at(1040), context: ctx)).count == 1)
    }

    @Test func seekingDoesNotCountAsListening() {
        var tracker = ScrobbleTracker()
        let ctx = context()
        _ = tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: ctx)
        _ = tracker.handle(.seeked(position: 190, at: at(5)), context: ctx)
        // Skipped to the next track 10 s after starting: only 10 s listened.
        let next = makeTrack("B")
        let actions = tracker.handle(.started(next, position: 0, playing: true, at: at(10)), context: ctx)
        #expect(scrobbles(actions).isEmpty)
    }

    @Test func atTrackEndModeDecidesWhenTrackChanges() {
        var tracker = ScrobbleTracker()
        let ctx = context { $0.submitTiming = .atTrackEnd }
        _ = tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: ctx)
        #expect(tracker.nextDecisionDate(context: ctx) == nil)
        #expect(tracker.tick(at: at(150), context: ctx).isEmpty)
        let actions = tracker.handle(.started(makeTrack("B"), position: 0, playing: true, at: at(200)), context: ctx)
        #expect(scrobbles(actions).map(\.track) == [track])
    }

    @Test func pausingScrobblingAtDecisionPointDropsThePlay() {
        var tracker = ScrobbleTracker()
        _ = tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: context())
        // Scrobbling paused when the threshold is crossed.
        #expect(tracker.tick(at: at(100), context: context(paused: true)).isEmpty)
        // Resuming scrobbling later in the same play doesn't resurrect it.
        #expect(tracker.handle(.stopped(at: at(200)), context: context()).isEmpty)
    }

    @Test func atTrackEndRespectsPauseAtEnd() {
        var tracker = ScrobbleTracker()
        let ctx = context { $0.submitTiming = .atTrackEnd }
        _ = tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: ctx)
        let paused = context({ $0.submitTiming = .atTrackEnd }, paused: true)
        #expect(tracker.handle(.stopped(at: at(200)), context: paused).isEmpty)
    }

    @Test func pausedScrobblingSuppressesNowPlaying() {
        var tracker = ScrobbleTracker()
        #expect(tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: context(paused: true)).isEmpty)
    }

    @Test func nowPlayingSentOnFirstResumeWhenStartedPaused() {
        var tracker = ScrobbleTracker()
        let ctx = context()
        #expect(tracker.handle(.started(track, position: 0, playing: false, at: at(0)), context: ctx).isEmpty)
        #expect(tracker.handle(.resumed(position: 0, at: at(5)), context: ctx) == [.nowPlaying(track)])
        #expect(tracker.handle(.paused(position: 1, at: at(6)), context: ctx).isEmpty)
        #expect(tracker.handle(.resumed(position: 1, at: at(7)), context: ctx).isEmpty)
    }

    @Test func shortTracksIgnoredTracksAndStreamsNeverScrobble() {
        for (candidate, ignored) in [(makeTrack(duration: 20), false), (makeTrack(duration: nil), false), (track, true)] {
            var tracker = ScrobbleTracker()
            let ctx = context(ignored: ignored)
            #expect(tracker.handle(.started(candidate, position: 0, playing: true, at: at(0)), context: ctx).isEmpty)
            #expect(tracker.handle(.stopped(at: at(1000)), context: ctx).isEmpty)
        }
    }

    @Test func repeatsFollowSetting() {
        for allowRepeats in [true, false] {
            var tracker = ScrobbleTracker()
            let ctx = context { $0.scrobbleRepeats = allowRepeats }
            _ = tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: ctx)
            _ = tracker.tick(at: at(100), context: ctx)
            _ = tracker.handle(.started(track, position: 0, playing: true, at: at(200)), context: ctx)
            let second = scrobbles(tracker.tick(at: at(300), context: ctx))
            #expect(second.count == (allowRepeats ? 1 : 0))
        }
    }

    @Test func lateTimerStillScrobblesAtTrackChange() {
        var tracker = ScrobbleTracker()
        let ctx = context()
        _ = tracker.handle(.started(track, position: 0, playing: true, at: at(0)), context: ctx)
        // The threshold timer never fired (e.g. app was busy); the next track still settles it.
        let actions = tracker.handle(.started(makeTrack("B"), position: 0, playing: true, at: at(150)), context: ctx)
        #expect(scrobbles(actions).count == 1)
    }

    @Test func customRulesTenPercentNoCap() {
        var tracker = ScrobbleTracker()
        let ctx = context {
            $0.thresholdPercent = 10
            $0.capEnabled = false
        }
        let long = makeTrack(duration: 3600)
        _ = tracker.handle(.started(long, position: 0, playing: true, at: at(0)), context: ctx)
        #expect(tracker.nextDecisionDate(context: ctx) == at(360))
    }
}
