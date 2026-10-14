import Foundation

/// Normalised playback events. Presence and scrobbling only ever see these.
public enum PlaybackEvent: Sendable, Equatable {
    /// A new track, or the same track starting over (repeat).
    case started(Track, position: TimeInterval, playing: Bool, at: Date)
    case resumed(position: TimeInterval, at: Date)
    case paused(position: TimeInterval, at: Date)
    case seeked(position: TimeInterval, at: Date)
    /// Music quit, playback stopped, or the Mac went to sleep.
    case stopped(at: Date)
}

/// Turns a stream of `PlayerSnapshot`s (from notifications and polling) into `PlaybackEvent`s.
///
/// Music.app does not announce seeks or repeat-one restarts, so both are inferred by comparing
/// the reported playhead with where it should be if playback had simply continued.
public struct PlaybackEngine: Sendable {
    /// Larger drifts than this between expected and reported position count as a seek.
    public static let seekTolerance: TimeInterval = 2
    /// A jump back to the start only counts as a repeat if the previous play was this close to the end.
    public static let repeatEndWindow: TimeInterval = 8
    public static let repeatStartWindow: TimeInterval = 5

    public private(set) var track: Track?
    public private(set) var state: PlayerState = .stopped
    private var anchorPosition: TimeInterval = 0
    private var anchorDate: Date = .distantPast

    public init() {}

    /// Where the playhead should be at `date`, extrapolating while playing.
    public func expectedPosition(at date: Date) -> TimeInterval {
        guard state == .playing else { return anchorPosition }
        return anchorPosition + max(0, date.timeIntervalSince(anchorDate))
    }

    public mutating func ingest(_ snapshot: PlayerSnapshot) -> [PlaybackEvent] {
        guard snapshot.state != .stopped, let newTrack = snapshot.track else {
            defer { reset() }
            return track == nil ? [] : [.stopped(at: snapshot.at)]
        }

        let position = snapshot.position ?? 0
        let isPlaying = snapshot.state == .playing
        let previousState = state
        let expected = expectedPosition(at: snapshot.at)
        let previousTrack = track

        track = newTrack
        state = snapshot.state
        anchorPosition = position
        anchorDate = snapshot.at

        guard let previousTrack, previousTrack.isSameTrack(as: newTrack) else {
            return [.started(newTrack, position: position, playing: isPlaying, at: snapshot.at)]
        }

        if Self.isRepeat(expected: expected, position: position, duration: newTrack.duration) {
            return [.started(newTrack, position: position, playing: isPlaying, at: snapshot.at)]
        }

        var events: [PlaybackEvent] = []
        switch (previousState, snapshot.state) {
        case (.paused, .playing): events.append(.resumed(position: position, at: snapshot.at))
        case (.playing, .paused): events.append(.paused(position: position, at: snapshot.at))
        default: break
        }
        if abs(position - expected) > Self.seekTolerance {
            events.append(.seeked(position: position, at: snapshot.at))
        }
        return events
    }

    private mutating func reset() {
        track = nil
        state = .stopped
        anchorPosition = 0
        anchorDate = .distantPast
    }

    static func isRepeat(expected: TimeInterval, position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return expected >= duration - repeatEndWindow
            && position <= repeatStartWindow
            && expected - position > seekTolerance
    }
}
