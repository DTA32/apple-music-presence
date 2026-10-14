import Foundation

/// Leading + trailing throttle for `SET_ACTIVITY`.
///
/// Discord allows 5 activity updates per 20 s. We send at most one per `interval`: the first
/// request goes out immediately, later ones within the window collapse into a single send
/// at the end of the window carrying the latest state.
public struct SendThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        case sendNow
        case sendAfter(TimeInterval)
        /// A trailing send is already scheduled and will pick up the latest state.
        case alreadyScheduled
    }

    public let interval: TimeInterval
    private var lastSent: Date?
    private var scheduled = false

    public init(interval: TimeInterval = 4) {
        self.interval = interval
    }

    public mutating func request(at now: Date) -> Decision {
        if scheduled { return .alreadyScheduled }
        guard let lastSent else { return .sendNow }
        let wait = interval - now.timeIntervalSince(lastSent)
        if wait <= 0 { return .sendNow }
        scheduled = true
        return .sendAfter(wait)
    }

    public mutating func didSend(at now: Date) {
        lastSent = now
        scheduled = false
    }

    /// Forget timing state (e.g. after reconnecting).
    public mutating func reset() {
        lastSent = nil
        scheduled = false
    }
}
