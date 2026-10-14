import AMPCore
import Foundation
@testable import LastFM
import Testing

/// Records requests and replies with canned responses, in order.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<(Int, String), URLError>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<(Int, String), URLError>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: Result<(Int, String), URLError> = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? .success((500, "")) : responses.removeFirst()
        }
        let (status, body) = try next.get()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func formBody(_ index: Int) -> [String: String] {
        let request = lock.withLock { requests[index] }
        let raw = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? request.url?.query ?? ""
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }
}

let credentials = LastFMCredentials(apiKey: "key", sharedSecret: "secret")
let sampleTrack = Track(persistentID: "A", title: "Song & Dance", artist: "Artíst", album: "Album", albumArtist: "Various", duration: 201.6, trackNumber: 3)

@Suite struct SignatureTests {
    @Test func knownVector() {
        // md5("api_keyxxxxmethodauth.getSessiontokenyyyyilovecher"), computed with `md5 -s`.
        let params = ["api_key": "xxxx", "method": "auth.getSession", "token": "yyyy", "format": "json"]
        #expect(LastFMSignature.sign(params, secret: "ilovecher") == "823df9939bce8abaf766d357c0eb08e1")
    }

    @Test func requestsAreSignedOverDecodedValues() async throws {
        let transport = FakeTransport([.success((200, #"{"nowplaying":{}}"#))])
        let client = LastFMClient(credentials: credentials, transport: transport)
        try await client.updateNowPlaying(sampleTrack, sessionKey: "sk1", sendAlbumArtist: true)
        var body = transport.formBody(0)
        #expect(body["format"] == "json")
        #expect(body["track"] == "Song & Dance")
        #expect(body["albumArtist"] == "Various")
        #expect(body["duration"] == "202")
        let signature = body.removeValue(forKey: "api_sig")
        #expect(signature == LastFMSignature.sign(body, secret: "secret"))
    }
}

@Suite struct ClientTests {
    @Test func scrobbleBatchParamsAndOutcomes() async throws {
        let response = #"""
        {"scrobbles":{"@attr":{"accepted":1,"ignored":1},"scrobble":[
          {"ignoredMessage":{"code":"0","#text":""}},
          {"ignoredMessage":{"code":"3","#text":""}}
        ]}}
        """#
        let transport = FakeTransport([.success((200, response))])
        let client = LastFMClient(credentials: credentials, transport: transport)
        let batch = [
            Scrobble(track: sampleTrack, timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            Scrobble(track: sampleTrack, timestamp: Date(timeIntervalSince1970: 1_600_000_000)),
        ]
        let outcomes = try await client.scrobble(batch, sessionKey: "sk", sendAlbumArtist: false)
        #expect(outcomes.map(\.isAccepted) == [true, false])
        #expect(outcomes[1].reason == "Timestamp too old")
        let body = transport.formBody(0)
        #expect(body["timestamp[0]"] == "1700000000")
        #expect(body["artist[1]"] == "Artíst")
        #expect(body["trackNumber[1]"] == "3")
        #expect(body["albumArtist[0]"] == nil) // disabled
    }

    @Test func singleScrobbleResponseIsAnObject() async throws {
        let response = ##"{"scrobbles":{"scrobble":{"ignoredMessage":{"code":"0","#text":""}}}}"##
        let client = LastFMClient(credentials: credentials, transport: FakeTransport([.success((200, response))]))
        let outcomes = try await client.scrobble([Scrobble(track: sampleTrack, timestamp: Date())], sessionKey: "sk", sendAlbumArtist: true)
        #expect(outcomes == [ScrobbleOutcome(ignoredCode: 0, ignoredMessage: "")])
    }

    @Test func apiErrorsAreClassified() async {
        let client = LastFMClient(credentials: credentials, transport: FakeTransport([.success((403, #"{"error":14,"message":"Unauthorized Token"}"#))]))
        await #expect(throws: LastFMError.api(code: 14, message: "Unauthorized Token")) {
            try await client.getSession(token: "t")
        }
        #expect(LastFMError.api(code: 14, message: "").isUnauthorizedToken)
        #expect(LastFMError.api(code: 9, message: "").isInvalidSession)
        #expect(LastFMError.api(code: 11, message: "").isRetryable)
        #expect(LastFMError.api(code: 16, message: "").isRetryable)
        #expect(!LastFMError.api(code: 6, message: "").isRetryable)
        #expect(LastFMError.network("offline").isRetryable)
        #expect(LastFMError.http(status: 503).isRetryable)
    }

    @Test func desktopAuthFlow() async throws {
        let transport = FakeTransport([
            .success((200, #"{"token":"tok123"}"#)),
            .success((200, #"{"session":{"name":"dta32","key":"sessionkey","subscriber":0}}"#)),
        ])
        let client = LastFMClient(credentials: credentials, transport: transport)
        let token = try await client.getToken()
        #expect(client.authorizationURL(token: token).absoluteString == "https://www.last.fm/api/auth/?api_key=key&token=tok123")
        #expect(try await client.getSession(token: token) == LastFMSession(username: "dta32", key: "sessionkey"))
        #expect(transport.formBody(1)["token"] == "tok123")
    }

    @Test func notConfiguredFailsFast() async {
        let client = LastFMClient(credentials: .init(apiKey: "", sharedSecret: ""), transport: FakeTransport([]))
        await #expect(throws: LastFMError.notConfigured) { try await client.getToken() }
    }
}

@Suite struct QueueAndSubmitterTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("amp-tests-\(UUID().uuidString)")
    }

    @Test func queuePersistsAcrossInstances() async throws {
        let url = tempDir().appendingPathComponent("queue.json")
        let queue = ScrobbleQueue(fileURL: url)
        let scrobble = Scrobble(track: sampleTrack, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try await queue.enqueue(scrobble)
        let reloaded = ScrobbleQueue(fileURL: url)
        #expect(await reloaded.nextBatch() == [scrobble])
        try await reloaded.remove(ids: [scrobble.id])
        #expect(await ScrobbleQueue(fileURL: url).count == 0)
    }

    @Test func historyIsCappedNewestFirst() async {
        let history = ScrobbleHistory(fileURL: tempDir().appendingPathComponent("history.json"))
        for i in 0..<60 {
            await history.record(Scrobble(track: sampleTrack, timestamp: Date(timeIntervalSince1970: Double(i))), status: .queued)
        }
        let entries = await history.entries
        #expect(entries.count == ScrobbleHistory.capacity)
        #expect(entries.first?.timestamp == Date(timeIntervalSince1970: 59))
    }

    @Test func networkFailureKeepsQueueAndRecordsOutcomeLater() async throws {
        let dir = tempDir()
        let transport = FakeTransport([
            .failure(URLError(.notConnectedToInternet)),
            .success((200, ##"{"scrobbles":{"scrobble":{"ignoredMessage":{"code":"0","#text":""}}}}"##)),
        ])
        let queue = ScrobbleQueue(fileURL: dir.appendingPathComponent("queue.json"))
        let history = ScrobbleHistory(fileURL: dir.appendingPathComponent("history.json"))
        let submitter = ScrobbleSubmitter(client: LastFMClient(credentials: credentials, transport: transport), queue: queue, history: history)
        await submitter.configure(sessionKey: "sk", sendAlbumArtist: true)

        let scrobble = Scrobble(track: sampleTrack, timestamp: Date())
        await submitter.enqueue(scrobble)
        #expect(await queue.count == 1)
        #expect(await history.entries.first?.status == .queued)

        await submitter.flush() // "network is back"
        #expect(await queue.count == 0)
        #expect(await history.entries.first?.status == .sent)
    }

    @Test func revokedSessionStopsAndKeepsQueue() async {
        let dir = tempDir()
        let transport = FakeTransport([.success((403, #"{"error":9,"message":"Invalid session key"}"#))])
        let queue = ScrobbleQueue(fileURL: dir.appendingPathComponent("queue.json"))
        let submitter = ScrobbleSubmitter(
            client: LastFMClient(credentials: credentials, transport: transport),
            queue: queue,
            history: ScrobbleHistory(fileURL: dir.appendingPathComponent("history.json"))
        )
        await submitter.configure(sessionKey: "sk", sendAlbumArtist: true)
        await submitter.enqueue(Scrobble(track: sampleTrack, timestamp: Date()))
        #expect(await queue.count == 1)
        #expect(transport.requests.count == 1) // no retry loop against a dead session
    }
}
