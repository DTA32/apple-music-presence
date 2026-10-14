import Foundation

/// Renders presence text templates such as `"{title} — {album}"`.
public enum Template {
    public static let placeholders = ["title", "artist", "album", "albumArtist", "year", "genre", "trackNumber", "composer"]

    /// Known placeholders are replaced (missing values become empty), unknown ones are left as typed.
    /// Whitespace is collapsed and dangling separators at either end are trimmed,
    /// so `"{title} · {album}"` with no album renders as just the title.
    public static func render(_ template: String, track: Track) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let close = template[index...].firstIndex(of: "}") {
                let key = String(template[template.index(after: index)..<close])
                if placeholders.contains(key) {
                    output += value(for: key, track: track) ?? ""
                    index = template.index(after: close)
                    continue
                }
            }
            output.append(template[index])
            index = template.index(after: index)
        }
        return tidy(output)
    }

    static func value(for key: String, track: Track) -> String? {
        switch key {
        case "title": track.title
        case "artist": track.artist
        case "album": track.album
        case "albumArtist": track.albumArtist ?? track.artist
        case "year": track.year.map(String.init)
        case "genre": track.genre
        case "trackNumber": track.trackNumber.map(String.init)
        case "composer": track.composer
        default: nil
        }
    }

    static func tidy(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let separators = CharacterSet(charactersIn: "-–—·•|,:/").union(.whitespaces)
        return collapsed.trimmingCharacters(in: separators)
    }
}
