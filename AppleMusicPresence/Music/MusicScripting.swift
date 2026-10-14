import AMPCore
import AppKit
import ImageIO

/// Reads Music.app's state via Apple Events (AppleScript).
///
/// ⚠️ Any Apple Event sent to Music *launches* it. Callers must check that Music is running first
/// (`MusicAppSource` does). The first call triggers the one-time "control Music" permission prompt.
final class MusicScripting {
    enum Failure: Error, Equatable {
        /// The user denied (or hasn't granted) Automation permission for Music.
        case notAuthorized
        case notRunning
        case script(code: Int, message: String)
    }

    private lazy var stateScript = NSAppleScript(source: Self.stateSource)
    private lazy var artworkScript = NSAppleScript(source: Self.artworkSource)

    func snapshot(at date: Date = Date()) throws(Failure) -> PlayerSnapshot {
        let result = try run(stateScript)
        return MusicScriptParser.parse(result, at: date)
    }

    /// The current track's embedded artwork, downsampled for the menu. Nil if there is none.
    func artwork(maxPixelSize: Int = 128) -> NSImage? {
        guard let result = try? run(artworkScript) else { return nil }
        let data = result.data
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    private func run(_ script: NSAppleScript?) throws(Failure) -> NSAppleEventDescriptor {
        guard let script else { throw .script(code: 0, message: "Script failed to compile") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            switch code {
            case -1743: throw .notAuthorized   // errAEEventNotPermitted
            case -600, -609: throw .notRunning // procNotFound, connectionInvalid
            default: throw .script(code: code, message: message)
            }
        }
        return result
    }

    // MARK: - Scripts

    /// Returns {state, position, id, name, artist, album, albumArtist, duration, trackNumber,
    /// genre, year, composer, streamTitle}. Each property is read in its own `try` because some
    /// don't exist on every track kind (e.g. radio stations).
    /// Note: avoid short variable names like `st`/`nd`/`rd`/`th`; AppleScript parses them as ordinals.
    static let stateSource = """
    tell application id "com.apple.Music"
        set stateText to player state as string
        if stateText is "stopped" then return {stateText}
        set playheadPosition to -1
        try
            set playheadPosition to player position
        end try
        try
            set theTrack to current track
        on error
            return {stateText, playheadPosition}
        end try
        set fields to {"", "", "", "", "", -1, 0, "", 0, "", ""}
        try
            set item 1 of fields to persistent ID of theTrack
        end try
        try
            set item 2 of fields to name of theTrack
        end try
        try
            set item 3 of fields to artist of theTrack
        end try
        try
            set item 4 of fields to album of theTrack
        end try
        try
            set item 5 of fields to album artist of theTrack
        end try
        try
            set item 6 of fields to duration of theTrack
        end try
        try
            set item 7 of fields to track number of theTrack
        end try
        try
            set item 8 of fields to genre of theTrack
        end try
        try
            set item 9 of fields to year of theTrack
        end try
        try
            set item 10 of fields to composer of theTrack
        end try
        try
            set item 11 of fields to current stream title
        end try
        return {stateText, playheadPosition} & fields
    end tell
    """

    static let artworkSource = """
    tell application id "com.apple.Music"
        try
            return raw data of artwork 1 of current track
        end try
        try
            return data of artwork 1 of current track
        end try
        return ""
    end tell
    """
}
