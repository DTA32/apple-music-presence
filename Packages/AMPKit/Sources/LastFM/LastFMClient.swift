import AMPCore
import CryptoKit
import Foundation

public struct LastFMCredentials: Sendable, Equatable {
    public var apiKey: String
    public var sharedSecret: String

    public init(apiKey: String, sharedSecret: String) {
        self.apiKey = apiKey
        self.sharedSecret = sharedSecret
    }

    public var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }
}

public struct LastFMSession: Codable, Sendable, Equatable {
    public var username: String
    public var key: String

    public init(username: String, key: String) {
        self.username = username
        self.key = key
    }
}

public enum LastFMError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured
    case api(code: Int, message: String)
    case http(status: Int)
    case network(String)
    case decoding(String)

    /// Per Last.fm's guidance: retry on 11 (service offline) and 16 (temporary error);
    /// also on 29 (rate limit), network failures and 5xx.
    public var isRetryable: Bool {
        switch self {
        case .network: true
        case .http(let status): status >= 500 || status == 429
        case .api(let code, _): [11, 16, 29].contains(code)
        case .notConfigured, .decoding: false
        }
    }

    /// Error 9: the session key was revoked; the user must reconnect.
    public var isInvalidSession: Bool {
        if case .api(9, _) = self { true } else { false }
    }

    /// Error 14 while polling `auth.getSession`: the user hasn't clicked Allow yet.
    public var isUnauthorizedToken: Bool {
        if case .api(14, _) = self { true } else { false }
    }

    public var description: String {
        switch self {
        case .notConfigured: "Last.fm API key is not configured"
        case .api(let code, let message): "Last.fm error \(code): \(message)"
        case .http(let status): "HTTP \(status)"
        case .network(let message): message
        case .decoding(let message): "Unexpected response: \(message)"
        }
    }
}

/// The per-scrobble result Last.fm reports. `ignoredCode == 0` means accepted.
public struct ScrobbleOutcome: Sendable, Equatable {
    public var ignoredCode: Int
    public var ignoredMessage: String

    public init(ignoredCode: Int, ignoredMessage: String) {
        self.ignoredCode = ignoredCode
        self.ignoredMessage = ignoredMessage
    }

    public var isAccepted: Bool { ignoredCode == 0 }

    /// Last.fm's documented ignore codes, for when it sends no message text.
    public var reason: String {
        if !ignoredMessage.isEmpty { return ignoredMessage }
        return switch ignoredCode {
        case 1: "Artist was ignored"
        case 2: "Track was ignored"
        case 3: "Timestamp too old"
        case 4: "Timestamp too new"
        case 5: "Daily scrobble limit exceeded"
        default: "Ignored (code \(ignoredCode))"
        }
    }
}

/// Signs a request: sort params by name, concatenate name+value, append the secret, MD5.
/// `format` and `callback` are excluded, per the Last.fm API spec.
public enum LastFMSignature {
    public static func sign(_ params: [String: String], secret: String) -> String {
        let base = params
            .filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public actor LastFMClient {
    public static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    private let credentials: LastFMCredentials
    private let transport: any HTTPTransport

    public init(credentials: LastFMCredentials, transport: any HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    // MARK: - Auth (desktop flow)

    public func getToken() async throws -> String {
        let json = try await call("auth.getToken", [:], post: false)
        guard let token = json["token"] as? String else { throw LastFMError.decoding("missing token") }
        return token
    }

    public nonisolated func authorizationURL(token: String) -> URL {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: credentials.apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return components.url!
    }

    /// Throws `.api(14, …)` until the user has approved the token in the browser.
    public func getSession(token: String) async throws -> LastFMSession {
        let json = try await call("auth.getSession", ["token": token], post: false)
        guard let session = json["session"] as? [String: Any],
              let name = session["name"] as? String,
              let key = session["key"] as? String
        else { throw LastFMError.decoding("missing session") }
        return LastFMSession(username: name, key: key)
    }

    // MARK: - Scrobbling

    public func updateNowPlaying(_ track: Track, sessionKey: String, sendAlbumArtist: Bool) async throws {
        var params = Self.trackParams(track, index: nil, sendAlbumArtist: sendAlbumArtist)
        params["sk"] = sessionKey
        _ = try await call("track.updateNowPlaying", params, post: true)
    }

    /// Submits up to 50 scrobbles. Returns one outcome per input, in order.
    public func scrobble(_ scrobbles: [Scrobble], sessionKey: String, sendAlbumArtist: Bool) async throws -> [ScrobbleOutcome] {
        precondition(scrobbles.count <= 50, "Last.fm accepts at most 50 scrobbles per request")
        var params: [String: String] = ["sk": sessionKey]
        for (index, scrobble) in scrobbles.enumerated() {
            params.merge(Self.trackParams(scrobble.track, index: index, sendAlbumArtist: sendAlbumArtist)) { $1 }
            params["timestamp[\(index)]"] = String(Int(scrobble.timestamp.timeIntervalSince1970))
        }
        let json = try await call("track.scrobble", params, post: true)
        return try Self.parseScrobbleOutcomes(json, expected: scrobbles.count)
    }

    // MARK: - Plumbing

    static func trackParams(_ track: Track, index: Int?, sendAlbumArtist: Bool) -> [String: String] {
        func key(_ name: String) -> String { index.map { "\(name)[\($0)]" } ?? name }
        var params = [key("artist"): track.artist, key("track"): track.title]
        if let album = track.album { params[key("album")] = album }
        if sendAlbumArtist, let albumArtist = track.albumArtist, albumArtist != track.artist {
            params[key("albumArtist")] = albumArtist
        }
        if let duration = track.duration { params[key("duration")] = String(Int(duration.rounded())) }
        if let number = track.trackNumber, number > 0 { params[key("trackNumber")] = String(number) }
        return params
    }

    static func parseScrobbleOutcomes(_ json: [String: Any], expected: Int) throws -> [ScrobbleOutcome] {
        guard let scrobbles = json["scrobbles"] as? [String: Any] else { throw LastFMError.decoding("missing scrobbles") }
        // Last.fm returns an object for a single scrobble and an array for several.
        let items: [[String: Any]]
        if let array = scrobbles["scrobble"] as? [[String: Any]] {
            items = array
        } else if let single = scrobbles["scrobble"] as? [String: Any] {
            items = [single]
        } else {
            items = []
        }
        let outcomes = items.map { item -> ScrobbleOutcome in
            let ignored = item["ignoredMessage"] as? [String: Any]
            let code = (ignored?["code"] as? String).flatMap(Int.init) ?? (ignored?["code"] as? Int) ?? 0
            return ScrobbleOutcome(ignoredCode: code, ignoredMessage: ignored?["#text"] as? String ?? "")
        }
        guard outcomes.count == expected else {
            throw LastFMError.decoding("expected \(expected) scrobble results, got \(outcomes.count)")
        }
        return outcomes
    }

    func call(_ method: String, _ params: [String: String], post: Bool) async throws -> [String: Any] {
        guard credentials.isConfigured else { throw LastFMError.notConfigured }
        var all = params
        all["method"] = method
        all["api_key"] = credentials.apiKey
        all["api_sig"] = LastFMSignature.sign(all, secret: credentials.sharedSecret)
        all["format"] = "json"

        let body = Self.formEncode(all)
        var request: URLRequest
        if post {
            request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        } else {
            request = URLRequest(url: URL(string: Self.endpoint.absoluteString + "?" + body)!)
        }
        request.timeoutInterval = 20
        request.setValue("AppleMusicPresence/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw LastFMError.network(error.localizedDescription)
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let code = json?["error"] as? Int {
            throw LastFMError.api(code: code, message: json?["message"] as? String ?? "")
        }
        guard (200..<300).contains(response.statusCode) else { throw LastFMError.http(status: response.statusCode) }
        guard let json else { throw LastFMError.decoding("not JSON") }
        return json
    }

    static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
