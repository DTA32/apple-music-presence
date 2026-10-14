import AMPCore
import Foundation
import Testing

let t0 = Date(timeIntervalSince1970: 1_760_000_000)

func makeTrack(_ id: String = "A", title: String = "Song", duration: TimeInterval? = 200) -> Track {
    Track(persistentID: id, title: title, artist: "Artist", album: "Album", duration: duration)
}

func snap(_ state: PlayerState, _ track: Track?, _ position: TimeInterval?, at offset: TimeInterval) -> PlayerSnapshot {
    PlayerSnapshot(state: state, track: track, position: position, at: t0.addingTimeInterval(offset))
}

@Suite struct PlaybackEngineTests {
    @Test func firstSnapshotStartsTrack() {
        var engine = PlaybackEngine()
        let track = makeTrack()
        #expect(engine.ingest(snap(.playing, track, 12, at: 0)) == [.started(track, position: 12, playing: true, at: t0)])
    }

    @Test func steadyPlaybackProducesNoEvents() {
        var engine = PlaybackEngine()
        _ = engine.ingest(snap(.playing, makeTrack(), 0, at: 0))
        #expect(engine.ingest(snap(.playing, makeTrack(), 5.3, at: 5)).isEmpty)
        #expect(engine.ingest(snap(.playing, makeTrack(), 10.1, at: 10)).isEmpty)
    }

    @Test func pauseAndResume() {
        var engine = PlaybackEngine()
        _ = engine.ingest(snap(.playing, makeTrack(), 0, at: 0))
        #expect(engine.ingest(snap(.paused, makeTrack(), 4, at: 4)) == [.paused(position: 4, at: t0.addingTimeInterval(4))])
        // Long pause: expected position must not keep advancing while paused.
        #expect(engine.ingest(snap(.playing, makeTrack(), 4, at: 100)) == [.resumed(position: 4, at: t0.addingTimeInterval(100))])
    }

    @Test func seekForwardAndBackDetected() {
        var engine = PlaybackEngine()
        _ = engine.ingest(snap(.playing, makeTrack(), 0, at: 0))
        #expect(engine.ingest(snap(.playing, makeTrack(), 120, at: 5)) == [.seeked(position: 120, at: t0.addingTimeInterval(5))])
        // Manual rewind to the start mid-track is a seek, not a repeat.
        #expect(engine.ingest(snap(.playing, makeTrack(), 1, at: 10)) == [.seeked(position: 1, at: t0.addingTimeInterval(10))])
    }

    @Test func repeatOneDetectedNearEnd() {
        var engine = PlaybackEngine()
        let track = makeTrack(duration: 200)
        _ = engine.ingest(snap(.playing, track, 190, at: 0))
        // 13 s later we'd expect 203 (past the end); Music reports 3 s into the same track.
        #expect(engine.ingest(snap(.playing, track, 3, at: 13)) == [.started(track, position: 3, playing: true, at: t0.addingTimeInterval(13))])
    }

    @Test func trackChange() {
        var engine = PlaybackEngine()
        _ = engine.ingest(snap(.playing, makeTrack("A"), 0, at: 0))
        let next = makeTrack("B", title: "Next")
        #expect(engine.ingest(snap(.playing, next, 0, at: 30)) == [.started(next, position: 0, playing: true, at: t0.addingTimeInterval(30))])
    }

    @Test func stopOnlyOnceAndOnlyIfSomethingWasPlaying() {
        var engine = PlaybackEngine()
        #expect(engine.ingest(snap(.stopped, nil, nil, at: 0)).isEmpty)
        _ = engine.ingest(snap(.playing, makeTrack(), 0, at: 1))
        #expect(engine.ingest(snap(.stopped, nil, nil, at: 2)) == [.stopped(at: t0.addingTimeInterval(2))])
        #expect(engine.ingest(snap(.stopped, nil, nil, at: 3)).isEmpty)
    }

    @Test func startingPausedThenPlaying() {
        var engine = PlaybackEngine()
        let track = makeTrack()
        #expect(engine.ingest(snap(.paused, track, 25, at: 0)) == [.started(track, position: 25, playing: false, at: t0)])
        #expect(engine.ingest(snap(.playing, track, 25, at: 60)) == [.resumed(position: 25, at: t0.addingTimeInterval(60))])
    }

    @Test func persistentIDConversionMatchesAppleScriptForm() {
        // From spike S1: notification PersistentID 3643242549328605255.
        #expect(Track.persistentID(fromSigned: 3_643_242_549_328_605_255) == "328F65CBBF51F047") // verified with osascript
        #expect(Track.persistentID(fromSigned: -1).count == 16)
        #expect(Track.persistentID(fromSigned: 255) == "00000000000000FF")
    }
}
