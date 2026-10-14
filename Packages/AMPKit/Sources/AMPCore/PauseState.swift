import Foundation

/// A temporary pause of presence or scrobbling, set from the menu or a hotkey.
public enum PauseState: Codable, Sendable, Equatable {
    case active
    /// `until == nil` means "until I resume".
    case paused(until: Date?)

    public func isPaused(at date: Date) -> Bool {
        switch self {
        case .active: false
        case .paused(let until): until.map { date < $0 } ?? true
        }
    }

    public var expiry: Date? {
        if case .paused(let until) = self { until } else { nil }
    }

    /// Start of the next calendar day in `calendar`'s time zone.
    public static func tomorrow(after date: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? date.addingTimeInterval(86_400)
    }
}
