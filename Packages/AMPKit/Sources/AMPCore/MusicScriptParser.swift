import Foundation

/// Turns the AppleScript result list from Music.app into a `PlayerSnapshot`.
///
/// Expected list: {state, position, persistentID, name, artist, album, albumArtist, duration,
/// trackNumber, genre, year, composer, streamTitle}. Shorter lists happen when Music is stopped
/// ({state}) or has no current track ({state, position}).
public enum MusicScriptParser {
    public static func parse(_ list: NSAppleEventDescriptor, at date: Date) -> PlayerSnapshot {
        func item(_ index: Int) -> NSAppleEventDescriptor? {
            index <= list.numberOfItems ? list.atIndex(index) : nil
        }
        func string(_ index: Int) -> String? {
            guard let d = item(index), !d.isMissingValue, let s = d.stringValue, !s.isEmpty else { return nil }
            return s
        }
        func number(_ index: Int) -> Double? {
            guard let d = item(index), !d.isMissingValue else { return nil }
            return d.doubleValue
        }

        let state: PlayerState = switch string(1) {
        case "playing", "fast forwarding", "rewinding": .playing
        case "paused": .paused
        default: .stopped
        }
        guard state != .stopped else { return PlayerSnapshot(state: .stopped, track: nil, position: nil, at: date) }

        let position = number(2).flatMap { $0 >= 0 ? $0 : nil }
        guard let persistentID = string(3) else {
            return PlayerSnapshot(state: state, track: nil, position: position, at: date)
        }

        var title = string(4) ?? ""
        var artist = string(5) ?? ""
        let duration = number(8).flatMap { $0 > 0 ? $0 : nil }
        var id = persistentID

        // Radio / live streams: the "track" is the station; the song is in the stream title,
        // usually "Artist - Title". Treat each stream title as its own track.
        if duration == nil, let streamTitle = string(13) {
            let parts = streamTitle.components(separatedBy: " - ")
            if parts.count >= 2 {
                artist = parts[0]
                title = parts.dropFirst().joined(separator: " - ")
            } else {
                title = streamTitle
            }
            id = "\(persistentID)|\(streamTitle)"
        }

        guard !title.isEmpty else { return PlayerSnapshot(state: state, track: nil, position: position, at: date) }

        let track = Track(
            persistentID: id,
            title: title,
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            album: string(6),
            albumArtist: string(7),
            duration: duration,
            trackNumber: number(9).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
            genre: string(10),
            year: number(11).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
            composer: string(12)
        )
        return PlayerSnapshot(state: state, track: track, position: position, at: date)
    }
}

extension NSAppleEventDescriptor {
    /// AppleScript's `missing value` arrives as a type descriptor with code 'msng'.
    public var isMissingValue: Bool {
        descriptorType == typeType && typeCodeValue == 0x6D73_6E67
    }
}
