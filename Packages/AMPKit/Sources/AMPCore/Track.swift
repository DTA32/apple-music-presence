import Foundation

/// A track as reported by Music.app, normalised. Empty strings from Music are stored as `nil`.
public struct Track: Hashable, Codable, Sendable {
    /// Music's persistent ID as 16 uppercase hex digits (the AppleScript form).
    public var persistentID: String
    public var title: String
    public var artist: String
    public var album: String?
    public var albumArtist: String?
    /// Seconds. `nil` for radio / live streams, which are never scrobbled.
    public var duration: TimeInterval?
    public var trackNumber: Int?
    public var genre: String?
    public var year: Int?
    public var composer: String?

    public init(
        persistentID: String,
        title: String,
        artist: String,
        album: String? = nil,
        albumArtist: String? = nil,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        genre: String? = nil,
        year: Int? = nil,
        composer: String? = nil
    ) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.trackNumber = trackNumber
        self.genre = genre
        self.year = year
        self.composer = composer
    }

    /// Same song, ignoring metadata that can be refined while playing.
    public func isSameTrack(as other: Track) -> Bool {
        persistentID == other.persistentID && title == other.title && artist == other.artist
    }

    /// The distributed notification carries the ID as a signed 64-bit number; AppleScript as hex.
    public static func persistentID(fromSigned value: Int64) -> String {
        let hex = String(UInt64(bitPattern: value), radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

public enum PlayerState: String, Codable, Sendable {
    case playing, paused, stopped
}

/// One observation of Music.app's state at a point in time.
public struct PlayerSnapshot: Sendable, Equatable {
    public var state: PlayerState
    public var track: Track?
    /// Playhead position in seconds, if known.
    public var position: TimeInterval?
    public var at: Date

    public init(state: PlayerState, track: Track?, position: TimeInterval?, at: Date) {
        self.state = state
        self.track = track
        self.position = position
        self.at = at
    }
}
