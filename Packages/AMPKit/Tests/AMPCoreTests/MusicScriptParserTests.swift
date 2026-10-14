import AMPCore
import Foundation
import Testing

private var missing: NSAppleEventDescriptor { NSAppleEventDescriptor(typeCode: 0x6D73_6E67) }

private func list(_ items: [Any]) -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    for (index, value) in items.enumerated() {
        let descriptor: NSAppleEventDescriptor = switch value {
        case let s as String: NSAppleEventDescriptor(string: s)
        case let i as Int: NSAppleEventDescriptor(int32: Int32(i))
        case let d as Double: NSAppleEventDescriptor(double: d)
        case let d as NSAppleEventDescriptor: d
        default: fatalError("unsupported")
        }
        list.insert(descriptor, at: index + 1)
    }
    return list
}

@Suite struct MusicScriptParserTests {
    // Shape captured from the real script on macOS 26.4 (osascript -s s).
    @Test func libraryTrack() throws {
        let result = list(["paused", 25.0, "328F65CBBF51F047", "Love Me Like a Friend", "Fly By Midnight",
                           "Happy About Everything Else...", "Fly By Midnight", 202.266998291016, 2, "Pop", 2019,
                           "Justin Breit, Justin Slaven & Derek Fuhrmann", missing])
        let snapshot = MusicScriptParser.parse(result, at: t0)
        #expect(snapshot.state == .paused)
        #expect(snapshot.position == 25)
        let track = try #require(snapshot.track)
        #expect(track.persistentID == "328F65CBBF51F047")
        #expect(track.title == "Love Me Like a Friend")
        #expect(track.albumArtist == "Fly By Midnight")
        #expect(track.duration == 202.266998291016)
        #expect(track.trackNumber == 2)
        #expect(track.year == 2019)
    }

    @Test func stopped() {
        let snapshot = MusicScriptParser.parse(list(["stopped"]), at: t0)
        #expect(snapshot.state == .stopped)
        #expect(snapshot.track == nil)
    }

    @Test func noCurrentTrack() {
        let snapshot = MusicScriptParser.parse(list(["playing", 3.0]), at: t0)
        #expect(snapshot.state == .playing)
        #expect(snapshot.track == nil)
    }

    @Test func emptyFieldsBecomeNil() throws {
        let result = list(["playing", 1.0, "ABC", "Song", "", "", "", 180.0, 0, "", 0, "", missing])
        let track = try #require(MusicScriptParser.parse(result, at: t0).track)
        #expect(track.artist == "Unknown Artist")
        #expect(track.album == nil)
        #expect(track.trackNumber == nil)
        #expect(track.year == nil)
        #expect(track.genre == nil)
    }

    @Test func radioStreamUsesStreamTitle() throws {
        let result = list(["playing", 812.0, "STATION", "Apple Music 1", "", "", "", missing, 0, "", 0, "", "Artist Name - Song - Live"])
        let track = try #require(MusicScriptParser.parse(result, at: t0).track)
        #expect(track.artist == "Artist Name")
        #expect(track.title == "Song - Live")
        #expect(track.duration == nil) // never scrobbled
        #expect(track.persistentID == "STATION|Artist Name - Song - Live")
    }
}
