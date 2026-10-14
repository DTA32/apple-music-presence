import AMPCore
import DiscordRPC
import Foundation

/// What presence should be right now, given playback state and settings.
public enum PresenceDecision: Equatable, Sendable {
    case clear
    case show(Activity)
    /// Show this until `until`, then re-evaluate (used for "clear after delay" while paused).
    case showUntil(Activity, until: Date)
}

public struct PresenceInput: Sendable, Equatable {
    public var track: Track?
    public var state: PlayerState
    /// Playhead position at `positionDate`.
    public var position: TimeInterval
    public var positionDate: Date
    /// When playback was paused, if it is paused.
    public var pausedSince: Date?
    public var artwork: ArtworkInfo?
    public var isPresencePaused: Bool
    public var isIgnored: Bool

    public init(track: Track?, state: PlayerState, position: TimeInterval, positionDate: Date, pausedSince: Date?, artwork: ArtworkInfo?, isPresencePaused: Bool, isIgnored: Bool) {
        self.track = track
        self.state = state
        self.position = position
        self.positionDate = positionDate
        self.pausedSince = pausedSince
        self.artwork = artwork
        self.isPresencePaused = isPresencePaused
        self.isIgnored = isIgnored
    }
}

public enum PresenceBuilder {
    /// Uploaded Rich Presence art asset keys on the Discord application.
    public static let logoAsset = "logo"
    public static let pausedAsset = "paused"

    public static func decide(_ input: PresenceInput, settings: PresenceSettings, now: Date) -> PresenceDecision {
        guard settings.enabled, !input.isPresencePaused, !input.isIgnored,
              let track = input.track, input.state != .stopped
        else { return .clear }

        if input.state == .playing {
            return .show(activity(for: input, track: track, settings: settings, playing: true))
        }

        // Paused.
        switch settings.pausedBehavior {
        case .clearImmediately:
            return .clear
        case .keepShowing:
            return .show(activity(for: input, track: track, settings: settings, playing: false))
        case .clearAfterDelay:
            let until = (input.pausedSince ?? now).addingTimeInterval(max(0, settings.pausedClearDelay))
            guard now < until else { return .clear }
            return .showUntil(activity(for: input, track: track, settings: settings, playing: false), until: until)
        }
    }

    public static func activity(for input: PresenceInput, track: Track, settings: PresenceSettings, playing: Bool) -> Activity {
        let artwork = input.artwork
        let links = settings.clickableLinks

        var timestamps: Activity.Timestamps?
        if playing, settings.showProgress, let duration = track.duration, duration > 0 {
            let start = input.positionDate.addingTimeInterval(-input.position)
            timestamps = .init(start: milliseconds(start), end: milliseconds(start.addingTimeInterval(duration)))
        }

        var largeImage = logoAsset
        if settings.showArtwork, let url = artwork?.artworkURL { largeImage = url.absoluteString }

        let largeText = Template.render(settings.largeTextTemplate, track: track)
        let assets = Activity.Assets(
            largeImage: largeImage,
            largeText: largeText.isEmpty ? nil : largeText,
            largeURL: links ? artwork?.albumURL?.absoluteString : nil,
            smallImage: playing ? nil : pausedAsset,
            smallText: playing ? nil : settings.pausedText
        )

        let buttons = [settings.button1, settings.button2]
            .compactMap { button(for: $0, track: track, artwork: artwork) }

        return Activity(
            type: settings.activityType.rawValue,
            statusDisplayType: settings.statusDisplay.rawValue,
            details: Template.render(settings.detailsTemplate, track: track),
            detailsURL: links ? artwork?.trackURL?.absoluteString : nil,
            state: Template.render(settings.stateTemplate, track: track),
            stateURL: links ? artwork?.artistURL?.absoluteString : nil,
            timestamps: timestamps,
            assets: assets,
            buttons: buttons.isEmpty ? nil : buttons
        ).sanitized()
    }

    static func button(for kind: PresenceButton, track: Track, artwork: ArtworkInfo?) -> Activity.Button? {
        switch kind {
        case .none:
            return nil
        case .appleMusic:
            if let url = artwork?.trackURL {
                return .init(label: "Listen on Apple Music", url: url.absoluteString)
            }
            var components = URLComponents(string: "https://music.apple.com/search")!
            components.queryItems = [URLQueryItem(name: "term", value: "\(track.artist) \(track.title)")]
            return components.url.map { .init(label: "Search on Apple Music", url: $0.absoluteString) }
        case .lastFM:
            return lastFMTrackURL(track).map { .init(label: "View on Last.fm", url: $0.absoluteString) }
        }
    }

    /// Last.fm track pages: /music/{artist}/_/{track}, spaces as "+".
    static func lastFMTrackURL(_ track: Track) -> URL? {
        func segment(_ text: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~ ")
            let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
            return encoded.replacingOccurrences(of: " ", with: "+")
        }
        return URL(string: "https://www.last.fm/music/\(segment(track.artist))/_/\(segment(track.title))")
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
