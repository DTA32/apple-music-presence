import AMPCore
import Foundation
import os

/// Finds album art and Apple Music links for a track via the public iTunes Search API,
/// so presence can show real covers without running an image proxy.
public actor ArtworkResolver {
    struct CacheEntry: Codable, Sendable {
        var info: ArtworkInfo?
        var fetchedAt: Date
    }

    static let positiveTTL: TimeInterval = 30 * 86_400
    static let negativeTTL: TimeInterval = 86_400
    static let maxEntries = 500

    private let transport: any HTTPTransport
    private let cacheURL: URL?
    private let country: String
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<ArtworkInfo?, Never>] = [:]
    private let log = Logger(subsystem: AMPLog.subsystem, category: "artwork")

    public init(transport: any HTTPTransport = URLSessionTransport(), cacheURL: URL?, country: String = Locale.current.region?.identifier ?? "US") {
        self.transport = transport
        self.cacheURL = cacheURL
        self.country = country
        if let cacheURL {
            cache = (try? JSONFile.read([String: CacheEntry].self, from: cacheURL)) ?? [:]
        }
    }

    public func lookup(_ track: Track) async -> ArtworkInfo? {
        let key = ITunesMatcher.cacheKey(for: track)
        if let entry = cache[key] {
            let ttl = entry.info == nil ? Self.negativeTTL : Self.positiveTTL
            if Date().timeIntervalSince(entry.fetchedAt) < ttl { return entry.info }
        }
        if let task = inFlight[key] { return await task.value }

        let task = Task { await self.fetch(track) }
        inFlight[key] = task
        let info = await task.value
        inFlight[key] = nil
        store(key, info)
        return info
    }

    private func fetch(_ track: Track) async -> ArtworkInfo? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: ITunesMatcher.searchTerm(for: track)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await transport.send(request)
            guard response.statusCode == 200 else {
                log.info("iTunes search HTTP \(response.statusCode)")
                return nil
            }
            let results = try JSONDecoder().decode(ITunesSearchResponse.self, from: data).results
            return ITunesMatcher.bestMatch(in: results, for: track).map(ITunesMatcher.artworkInfo)
        } catch {
            log.info("iTunes search failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func store(_ key: String, _ info: ArtworkInfo?) {
        cache[key] = CacheEntry(info: info, fetchedAt: Date())
        if cache.count > Self.maxEntries {
            let oldest = cache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.prefix(cache.count - Self.maxEntries)
            for (key, _) in oldest { cache[key] = nil }
        }
        if let cacheURL { try? JSONFile.write(cache, to: cacheURL) }
    }
}

struct ITunesSearchResponse: Decodable {
    var results: [ITunesSong]
}

struct ITunesSong: Decodable, Equatable {
    var kind: String?
    var artistName: String?
    var collectionName: String?
    var trackName: String?
    var trackViewUrl: String?
    var artistViewUrl: String?
    var collectionViewUrl: String?
    var artworkUrl100: String?
}

enum ITunesMatcher {
    static func cacheKey(for track: Track) -> String {
        [track.artist, track.album ?? "", track.title].map(normalize).joined(separator: "|")
    }

    static func searchTerm(for track: Track) -> String {
        "\(stripDecorations(track.artist)) \(stripDecorations(track.title))"
    }

    /// Requires the artist and title to match; a matching album wins ties.
    /// Returning nothing beats returning the wrong cover.
    static func bestMatch(in results: [ITunesSong], for track: Track) -> ITunesSong? {
        let artist = normalize(track.artist)
        let title = normalize(track.title)
        let album = track.album.map(normalize)

        var best: (song: ITunesSong, score: Int)?
        for song in results where song.kind == nil || song.kind == "song" {
            guard let songArtist = song.artistName.map(normalize), let songTitle = song.trackName.map(normalize) else { continue }
            guard looselyEqual(artist, songArtist), looselyEqual(title, songTitle) else { continue }
            var score = 0
            if artist == songArtist { score += 2 }
            if title == songTitle { score += 2 }
            if let album, let songAlbum = song.collectionName.map(normalize) {
                if album == songAlbum { score += 3 } else if looselyEqual(album, songAlbum) { score += 1 }
            }
            // Normalising strips "(Taylor's Version)", "[Deluxe]" etc., which makes different editions
            // tie. An exact match on the raw text breaks the tie towards the edition actually playing.
            if exactlyEqual(track.title, song.trackName) { score += 1 }
            if exactlyEqual(track.album, song.collectionName) { score += 2 }
            if best == nil || score > best!.score { best = (song, score) }
        }
        return best?.song
    }

    static func artworkInfo(from song: ITunesSong) -> ArtworkInfo {
        ArtworkInfo(
            artworkURL: song.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) },
            trackURL: song.trackViewUrl.flatMap(cleanStoreURL),
            artistURL: song.artistViewUrl.flatMap(cleanStoreURL),
            albumURL: song.collectionViewUrl.flatMap(cleanStoreURL)
        )
    }

    /// Drops iTunes affiliate/tracking params (`uo=4`) but keeps `?i=` (the song within the album).
    static func cleanStoreURL(_ string: String) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name == "i" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    static func exactlyEqual(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func looselyEqual(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Lowercased, accent-free, without "(feat. …)", "[Remastered]", " - Single" and punctuation.
    static func normalize(_ text: String) -> String {
        let stripped = stripDecorations(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let allowed = stripped.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(allowed).split(separator: " ").joined(separator: " ")
    }

    static func stripDecorations(_ text: String) -> String {
        var result = text
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+-\s+(Single|EP)$"#, #"\s+(feat\.|ft\.|featuring)\s.*$"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
