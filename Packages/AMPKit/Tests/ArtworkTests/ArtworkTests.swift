import AMPCore
@testable import Artwork
import Foundation
import Testing

private func song(_ artist: String, _ title: String, _ album: String, id: Int = 1) -> ITunesSong {
    ITunesSong(
        kind: "song",
        artistName: artist,
        collectionName: album,
        trackName: title,
        trackViewUrl: "https://music.apple.com/us/album/x/\(id)?i=\(id * 10)&uo=4",
        artistViewUrl: "https://music.apple.com/us/artist/a/\(id)?uo=4",
        collectionViewUrl: "https://music.apple.com/us/album/x/\(id)?uo=4",
        artworkUrl100: "https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg"
    )
}

@Suite struct ITunesMatcherTests {
    let track = Track(persistentID: "A", title: "Love Me Like a Friend", artist: "Fly By Midnight", album: "Happy About Everything Else...")

    @Test func prefersExactAlbum() {
        let results = [
            song("Fly By Midnight", "Love Me Like a Friend", "Love Me Like a Friend - Single", id: 1),
            song("Fly By Midnight", "Love Me Like a Friend", "Happy About Everything Else...", id: 2),
        ]
        #expect(ITunesMatcher.bestMatch(in: results, for: track) == results[1])
    }

    @Test func exactEditionWinsOverReRecording() {
        let original = Track(persistentID: "C", title: "Style", artist: "Taylor Swift", album: "1989 (Deluxe Edition)")
        let results = [
            song("Taylor Swift", "Style (Taylor's Version)", "1989 (Taylor's Version) [Deluxe]", id: 1),
            song("Taylor Swift", "Style", "1989 (Deluxe Edition)", id: 2),
        ]
        #expect(ITunesMatcher.bestMatch(in: results, for: original) == results[1])
        let rerecorded = Track(persistentID: "D", title: "Style (Taylor's Version)", artist: "Taylor Swift", album: "1989 (Taylor's Version) [Deluxe]")
        #expect(ITunesMatcher.bestMatch(in: results.reversed(), for: rerecorded) == results[0])
    }

    @Test func rejectsWrongArtistRatherThanGuessing() {
        let results = [song("Someone Else", "Love Me Like a Friend", "Covers")]
        #expect(ITunesMatcher.bestMatch(in: results, for: track) == nil)
    }

    @Test func toleratesDecorations() {
        let decorated = Track(persistentID: "B", title: "Song (feat. Guest) [Remastered 2011]", artist: "Beyoncé", album: "Album - EP")
        let results = [song("Beyonce", "Song", "Album")]
        #expect(ITunesMatcher.bestMatch(in: results, for: decorated) != nil)
    }

    @Test func artworkInfoUpscalesAndCleansURLs() {
        let info = ITunesMatcher.artworkInfo(from: song("A", "B", "C", id: 7))
        #expect(info.artworkURL?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg")
        #expect(info.trackURL?.absoluteString == "https://music.apple.com/us/album/x/7?i=70")
        #expect(info.artistURL?.absoluteString == "https://music.apple.com/us/artist/a/7")
    }
}

final class CountingTransport: HTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    let body: String

    init(body: String) { self.body = body }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct ArtworkResolverTests {
    @Test func cachesHitsAndMissesOnDisk() async throws {
        let body = #"{"resultCount":1,"results":[{"kind":"song","artistName":"Fly By Midnight","trackName":"Love Me Like a Friend","collectionName":"Happy About Everything Else...","artworkUrl100":"https://x/100x100bb.jpg"}]}"#
        let transport = CountingTransport(body: body)
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("amp-art-\(UUID().uuidString).json")
        let track = Track(persistentID: "A", title: "Love Me Like a Friend", artist: "Fly By Midnight", album: "Happy About Everything Else...")
        let miss = Track(persistentID: "B", title: "Unknown", artist: "Nobody")

        let resolver = ArtworkResolver(transport: transport, cacheURL: cacheURL, country: "ID")
        #expect(await resolver.lookup(track)?.artworkURL?.absoluteString == "https://x/600x600bb.jpg")
        #expect(await resolver.lookup(miss) == nil)
        _ = await resolver.lookup(track)
        _ = await resolver.lookup(miss)
        #expect(transport.count == 2)

        // A fresh resolver reuses the on-disk cache.
        let again = ArtworkResolver(transport: transport, cacheURL: cacheURL, country: "ID")
        _ = await again.lookup(track)
        #expect(transport.count == 2)
    }
}

/// Hits the real iTunes Search API. Opt-in: AMP_LIVE_NETWORK=1 swift test --filter LiveArtwork
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AMP_LIVE_NETWORK"] == "1"))
struct LiveArtworkTests {
    @Test(arguments: ["ID", "US"])
    func catalogueTrackResolves(country: String) async throws {
        let resolver = ArtworkResolver(cacheURL: nil, country: country)
        let track = Track(persistentID: "live", title: "Style", artist: "Taylor Swift", album: "1989 (Deluxe Edition)")
        let info = try #require(await resolver.lookup(track))
        print(country, info.artworkURL?.absoluteString ?? "-", info.trackURL?.absoluteString ?? "-")
        #expect(info.artworkURL?.absoluteString.contains("600x600bb") == true)
        #expect(info.trackURL?.host() == "music.apple.com")
    }
}
