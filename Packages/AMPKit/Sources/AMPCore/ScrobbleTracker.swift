import Foundation

public struct Scrobble: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var track: Track
    /// When the track started playing (Last.fm wants the start time).
    public var timestamp: Date

    public init(id: UUID = UUID(), track: Track, timestamp: Date) {
        self.id = id
        self.track = track
        self.timestamp = timestamp
    }
}

public enum ScrobbleAction: Sendable, Equatable {
    case nowPlaying(Track)
    case scrobble(Scrobble)
}

/// Decides when a play counts as a scrobble.
///
/// Counts *listened* time (wall clock while playing), so seeking can't game the threshold
/// and time spent paused doesn't count. A scrobble decision happens once per play, at the
/// "decision point": crossing the threshold (`.atThreshold`) or the play ending (`.atTrackEnd`).
/// If scrobbling is paused at the decision point, that play is dropped.
public struct ScrobbleTracker: Sendable {
    public struct Context: Sendable {
        public var settings: ScrobbleSettings
        public var isPaused: Bool
        public var isIgnored: @Sendable (Track) -> Bool

        public init(settings: ScrobbleSettings, isPaused: Bool, isIgnored: @escaping @Sendable (Track) -> Bool = { _ in false }) {
            self.settings = settings
            self.isPaused = isPaused
            self.isIgnored = isIgnored
        }
    }

    struct Session: Sendable {
        var track: Track
        var startedAt: Date
        var listened: TimeInterval = 0
        var playingSince: Date?
        var decided = false
        var nowPlayingSent = false
        var isRepeat: Bool
    }

    private(set) var session: Session?
    private var previousTrack: Track?

    public init() {}

    public var currentTrack: Track? { session?.track }

    public mutating func handle(_ event: PlaybackEvent, context: Context) -> [ScrobbleAction] {
        switch event {
        case let .started(track, _, playing, at):
            var actions = finish(at: at, context: context)
            let isRepeat = previousTrack.map { $0.persistentID == track.persistentID } ?? false
            session = Session(track: track, startedAt: at, playingSince: playing ? at : nil, isRepeat: isRepeat)
            previousTrack = track
            if playing { actions += nowPlayingIfNeeded(context: context) }
            return actions

        case let .resumed(_, at):
            guard session != nil else { return [] }
            session?.playingSince = at
            return nowPlayingIfNeeded(context: context)

        case let .paused(_, at):
            accumulate(at: at)
            session?.playingSince = nil
            return thresholdCheck(context: context)

        case .seeked:
            return []

        case let .stopped(at):
            let actions = finish(at: at, context: context)
            session = nil
            return actions
        }
    }

    /// Call at `nextDecisionDate` (or any time) while playing.
    public mutating func tick(at date: Date, context: Context) -> [ScrobbleAction] {
        accumulate(at: date)
        return thresholdCheck(context: context)
    }

    /// When the current play will cross its threshold if it keeps playing (`.atThreshold` only).
    public func nextDecisionDate(context: Context) -> Date? {
        guard context.settings.submitTiming == .atThreshold,
              let session, !session.decided, let since = session.playingSince,
              let duration = session.track.duration, isEligible(session, context: context)
        else { return nil }
        let remaining = context.settings.threshold(forDuration: duration) - session.listened
        return since.addingTimeInterval(max(0, remaining))
    }

    /// Listened seconds and threshold of the current play, for display.
    public func progress(at date: Date, settings: ScrobbleSettings) -> (listened: TimeInterval, threshold: TimeInterval)? {
        guard let session, let duration = session.track.duration else { return nil }
        let running = session.playingSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return (session.listened + running, settings.threshold(forDuration: duration))
    }

    // MARK: - Internals

    private mutating func accumulate(at date: Date) {
        guard let since = session?.playingSince else { return }
        session?.listened += max(0, date.timeIntervalSince(since))
        session?.playingSince = date
    }

    private mutating func thresholdCheck(context: Context) -> [ScrobbleAction] {
        guard context.settings.submitTiming == .atThreshold else { return [] }
        return decideIfThresholdReached(context: context)
    }

    private mutating func finish(at date: Date, context: Context) -> [ScrobbleAction] {
        accumulate(at: date)
        return decideIfThresholdReached(context: context)
    }

    private mutating func decideIfThresholdReached(context: Context) -> [ScrobbleAction] {
        guard var current = session, !current.decided,
              let duration = current.track.duration,
              isEligible(current, context: context),
              current.listened >= context.settings.threshold(forDuration: duration)
        else { return [] }
        current.decided = true
        session = current
        guard !context.isPaused else { return [] }
        return [.scrobble(Scrobble(track: current.track, timestamp: current.startedAt))]
    }

    private mutating func nowPlayingIfNeeded(context: Context) -> [ScrobbleAction] {
        guard let current = session, !current.nowPlayingSent,
              context.settings.sendNowPlaying, !context.isPaused,
              isEligible(current, context: context)
        else { return [] }
        session?.nowPlayingSent = true
        return [.nowPlaying(current.track)]
    }

    private func isEligible(_ session: Session, context: Context) -> Bool {
        context.settings.enabled
            && context.settings.isLongEnough(session.track)
            && !(session.isRepeat && !context.settings.scrobbleRepeats)
            && !context.isIgnored(session.track)
    }
}
