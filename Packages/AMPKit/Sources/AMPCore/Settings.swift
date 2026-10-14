import Foundation

// MARK: - Presence

public enum PresenceActivityType: Int, Codable, Sendable, CaseIterable {
    case playing = 0
    case listening = 2
}

/// What Discord shows as the status text in the member list (`status_display_type`).
public enum StatusDisplay: Int, Codable, Sendable, CaseIterable {
    case appName = 0
    case state = 1
    case details = 2
}

public enum PausedBehavior: String, Codable, Sendable, CaseIterable {
    case clearImmediately
    case clearAfterDelay
    case keepShowing
}

public enum PresenceButton: String, Codable, Sendable, CaseIterable {
    case none
    case appleMusic
    case lastFM
}

public struct PresenceSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var activityType: PresenceActivityType = .listening
    public var statusDisplay: StatusDisplay = .state
    public var detailsTemplate = "{title}"
    public var stateTemplate = "{artist}"
    public var largeTextTemplate = "{album}"
    public var showArtwork = true
    public var showProgress = true
    public var clickableLinks = true
    public var button1: PresenceButton = .appleMusic
    public var button2: PresenceButton = .none
    public var pausedBehavior: PausedBehavior = .clearAfterDelay
    public var pausedClearDelay: TimeInterval = 30
    public var pausedText = "Paused"
    /// Empty = use the client ID bundled at build time.
    public var clientIDOverride = ""

    public init() {}
}

// MARK: - Scrobbling

public enum SubmitTiming: String, Codable, Sendable, CaseIterable {
    /// Enqueue the moment listened time crosses the threshold.
    case atThreshold
    /// Decide when the track ends, is skipped, or playback stops.
    case atTrackEnd
}

public struct ScrobbleSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var sendNowPlaying = true
    /// 1...100
    public var thresholdPercent: Double = 50
    public var capEnabled = true
    public var capSeconds: TimeInterval = 240
    public var minTrackLength: TimeInterval = 30
    public var submitTiming: SubmitTiming = .atThreshold
    public var scrobbleRepeats = true
    public var sendAlbumArtist = true

    public init() {}

    /// Listened seconds needed before `track` counts as scrobbled.
    public func threshold(forDuration duration: TimeInterval) -> TimeInterval {
        let percent = min(max(thresholdPercent, 1), 100)
        let byPercent = duration * percent / 100
        return capEnabled ? min(byPercent, max(capSeconds, 0)) : byPercent
    }

    public func isLongEnough(_ track: Track) -> Bool {
        guard let duration = track.duration, duration > 0 else { return false }
        return duration >= minTrackLength
    }
}

// MARK: - Hotkeys

/// A global shortcut. `carbonModifiers` uses Carbon's cmdKey/shiftKey/optionKey/controlKey bits.
public struct KeyCombo: Codable, Sendable, Hashable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    /// Human-readable form, e.g. "⌃⌥⌘S", captured when the shortcut was recorded.
    public var display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    // Carbon modifier bits (Carbon.HIToolbox.Events), duplicated so AMPCore stays Carbon-free.
    public static let cmd: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public static let defaultToggleScrobbling = KeyCombo(keyCode: 0x01, carbonModifiers: control | option | cmd, display: "⌃⌥⌘S")
    public static let defaultTogglePresence = KeyCombo(keyCode: 0x02, carbonModifiers: control | option | cmd, display: "⌃⌥⌘D")

    /// Since macOS 15, shortcuts whose only modifiers are ⌥ or ⌥⇧ are refused by the system.
    public var isAllowedBySystem: Bool {
        carbonModifiers & (Self.cmd | Self.control) != 0
    }
}

public struct HotkeySettings: Codable, Sendable, Equatable {
    public var toggleScrobbling: KeyCombo? = .defaultToggleScrobbling
    public var togglePresence: KeyCombo? = .defaultTogglePresence

    public init() {}

    enum CodingKeys: String, CodingKey {
        case toggleScrobbling, togglePresence
    }

    /// Encodes a cleared shortcut as an explicit `null`. Omitting it would let
    /// `SettingsCodec`'s merge-over-defaults bring the default shortcut back.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toggleScrobbling, forKey: .toggleScrobbling)
        try container.encode(togglePresence, forKey: .togglePresence)
    }
}

// MARK: - Root

public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = AppSettings.currentVersion
    public var presence = PresenceSettings()
    public var scrobbling = ScrobbleSettings()
    public var ignoreRules: [IgnoreRule] = []
    public var hotkeys = HotkeySettings()
    /// Show a macOS notification banner when a hotkey pauses or resumes something.
    public var showPauseBanners = false

    public init() {}
}

/// Encodes settings, and decodes them forgivingly: stored JSON is deep-merged over the defaults,
/// so settings saved by an older build (missing keys) still load, with new keys at their defaults.
public enum SettingsCodec {
    public static func encode(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    public static func decode(_ data: Data) throws -> AppSettings {
        let defaults = try JSONSerialization.jsonObject(with: encode(AppSettings()))
        let stored = try JSONSerialization.jsonObject(with: data)
        let merged = deepMerge(defaults, stored)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        var settings = try JSONDecoder().decode(AppSettings.self, from: mergedData)
        settings.version = AppSettings.currentVersion
        return settings
    }

    /// Objects merge key by key; anything else (including arrays) is replaced by `override`.
    static func deepMerge(_ base: Any, _ override: Any) -> Any {
        guard let base = base as? [String: Any], let override = override as? [String: Any] else {
            return override
        }
        var result = base
        for (key, value) in override {
            result[key] = result[key].map { deepMerge($0, value) } ?? value
        }
        return result
    }
}
