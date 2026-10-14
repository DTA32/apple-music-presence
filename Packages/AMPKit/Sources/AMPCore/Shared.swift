import Foundation

/// Links and artwork for a track, resolved from the Apple Music catalogue.
public struct ArtworkInfo: Codable, Sendable, Equatable {
    public var artworkURL: URL?
    public var trackURL: URL?
    public var artistURL: URL?
    public var albumURL: URL?

    public init(artworkURL: URL? = nil, trackURL: URL? = nil, artistURL: URL? = nil, albumURL: URL? = nil) {
        self.artworkURL = artworkURL
        self.trackURL = trackURL
        self.artistURL = artistURL
        self.albumURL = albumURL
    }
}

/// Minimal HTTP seam so the Last.fm and iTunes clients can be tested without the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum AMPLog {
    public static let subsystem = "dev.dta32.applemusicpresence"
}

/// Writes a Codable value as JSON atomically, creating the parent directory if needed.
public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}
