import Foundation

/// Discord's Activity object, as sent with `SET_ACTIVITY`. `nil` fields are omitted from the JSON.
public struct Activity: Codable, Sendable, Equatable {
    public var type: Int?
    public var statusDisplayType: Int?
    public var details: String?
    public var detailsURL: String?
    public var state: String?
    public var stateURL: String?
    public var timestamps: Timestamps?
    public var assets: Assets?
    public var buttons: [Button]?

    public init(
        type: Int? = nil,
        statusDisplayType: Int? = nil,
        details: String? = nil,
        detailsURL: String? = nil,
        state: String? = nil,
        stateURL: String? = nil,
        timestamps: Timestamps? = nil,
        assets: Assets? = nil,
        buttons: [Button]? = nil
    ) {
        self.type = type
        self.statusDisplayType = statusDisplayType
        self.details = details
        self.detailsURL = detailsURL
        self.state = state
        self.stateURL = stateURL
        self.timestamps = timestamps
        self.assets = assets
        self.buttons = buttons
    }

    enum CodingKeys: String, CodingKey {
        case type
        case statusDisplayType = "status_display_type"
        case details
        case detailsURL = "details_url"
        case state
        case stateURL = "state_url"
        case timestamps, assets, buttons
    }

    /// Unix milliseconds. Sending both start and end shows a progress bar for Listening activities.
    public struct Timestamps: Codable, Sendable, Equatable {
        public var start: Int64?
        public var end: Int64?

        public init(start: Int64? = nil, end: Int64? = nil) {
            self.start = start
            self.end = end
        }
    }

    public struct Assets: Codable, Sendable, Equatable {
        /// An uploaded asset key (e.g. "logo") or an https URL.
        public var largeImage: String?
        public var largeText: String?
        public var largeURL: String?
        public var smallImage: String?
        public var smallText: String?

        public init(largeImage: String? = nil, largeText: String? = nil, largeURL: String? = nil, smallImage: String? = nil, smallText: String? = nil) {
            self.largeImage = largeImage
            self.largeText = largeText
            self.largeURL = largeURL
            self.smallImage = smallImage
            self.smallText = smallText
        }

        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
            case largeURL = "large_url"
            case smallImage = "small_image"
            case smallText = "small_text"
        }
    }

    public struct Button: Codable, Sendable, Equatable {
        public var label: String
        public var url: String

        public init(label: String, url: String) {
            self.label = label
            self.url = url
        }
    }
}

extension Activity {
    /// Discord rejects text fields outside 2...128 characters and buttons outside its limits.
    /// Truncates long text with an ellipsis, pads 1-character text, drops empty text,
    /// and drops invalid buttons rather than letting the whole update fail.
    public func sanitized() -> Activity {
        var copy = self
        copy.details = Self.clampText(details)
        copy.state = Self.clampText(state)
        copy.detailsURL = Self.clampURL(detailsURL)
        copy.stateURL = Self.clampURL(stateURL)
        if var assets = copy.assets {
            assets.largeText = Self.clampText(assets.largeText)
            assets.smallText = Self.clampText(assets.smallText)
            assets.largeURL = Self.clampURL(assets.largeURL)
            if let image = assets.largeImage, image.count > 256 { assets.largeImage = nil }
            copy.assets = assets
        }
        let buttons = (buttons ?? []).compactMap { button -> Button? in
            let label = String(button.label.prefix(32))
            guard !label.isEmpty, let url = Self.clampURL(button.url) else { return nil }
            return Button(label: label, url: url)
        }.prefix(2)
        copy.buttons = buttons.isEmpty ? nil : Array(buttons)
        return copy
    }

    static let maxTextLength = 128

    static func clampText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.count > maxTextLength {
            return String(text.prefix(maxTextLength - 1)) + "…"
        }
        // Discord requires at least 2 characters; pad with an invisible character.
        return text.count < 2 ? text + "\u{2800}" : text
    }

    static func clampURL(_ url: String?) -> String? {
        guard let url, url.count <= 512, url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        return url
    }
}
