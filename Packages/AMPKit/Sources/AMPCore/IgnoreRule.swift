import Foundation

/// "Don't share / don't scrobble tracks where <field> <matches> <value>".
public struct IgnoreRule: Codable, Sendable, Hashable, Identifiable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case artist, album, title, genre
    }

    public enum Match: String, Codable, Sendable, CaseIterable {
        case contains, equals, regex
    }

    public enum Scope: String, Codable, Sendable, CaseIterable {
        case both, presence, scrobbling
    }

    public enum Purpose: Sendable {
        case presence, scrobbling
    }

    public var id: UUID
    public var field: Field
    public var match: Match
    public var value: String
    public var scope: Scope

    public init(id: UUID = UUID(), field: Field = .artist, match: Match = .contains, value: String = "", scope: Scope = .both) {
        self.id = id
        self.field = field
        self.match = match
        self.value = value
        self.scope = scope
    }

    public func applies(to purpose: Purpose) -> Bool {
        switch (scope, purpose) {
        case (.both, _), (.presence, .presence), (.scrobbling, .scrobbling): true
        default: false
        }
    }

    /// Case- and diacritic-insensitive. An empty value or an invalid regex never matches.
    public func matches(_ track: Track) -> Bool {
        guard !value.isEmpty else { return false }
        let candidate: String? = switch field {
        case .artist: track.artist
        case .album: track.album
        case .title: track.title
        case .genre: track.genre
        }
        guard let candidate else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        switch match {
        case .contains:
            return candidate.range(of: value, options: options) != nil
        case .equals:
            return candidate.compare(value, options: options) == .orderedSame
        case .regex:
            return candidate.range(of: value, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

extension Array where Element == IgnoreRule {
    public func ignores(_ track: Track, for purpose: IgnoreRule.Purpose) -> Bool {
        contains { $0.applies(to: purpose) && $0.matches(track) }
    }
}
