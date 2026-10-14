import AMPCore
import Foundation
import os

/// Drains the `ScrobbleQueue` to Last.fm with retry/backoff, and records outcomes in the history.
public actor ScrobbleSubmitter {
    public enum Status: Sendable, Equatable {
        case idle
        case sending
        /// Waiting to retry after a temporary failure.
        case retrying(at: Date, reason: String)
        /// Session revoked (error 9). Queue is kept until the user reconnects.
        case needsReconnect
        case notConnected
    }

    public struct Snapshot: Sendable, Equatable {
        public var status: Status
        public var queued: Int
        public var history: [ScrobbleHistory.Entry]
        /// Most recent "ignored" reason, if the last submission had one.
        public var lastIgnored: String?

        public init(status: Status, queued: Int, history: [ScrobbleHistory.Entry], lastIgnored: String?) {
            self.status = status
            self.queued = queued
            self.history = history
            self.lastIgnored = lastIgnored
        }
    }

    public nonisolated let updates: AsyncStream<Snapshot>
    private let continuation: AsyncStream<Snapshot>.Continuation

    private let client: LastFMClient
    private let queue: ScrobbleQueue
    private let history: ScrobbleHistory
    private let log = Logger(subsystem: AMPLog.subsystem, category: "lastfm")

    private var sessionKey: String?
    private var sendAlbumArtist = true
    private var status: Status = .notConnected
    private var lastIgnored: String?
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?
    private var backoff: TimeInterval = ScrobbleSubmitter.minBackoff

    static let minBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 30 * 60

    public init(client: LastFMClient, queue: ScrobbleQueue, history: ScrobbleHistory) {
        self.client = client
        self.queue = queue
        self.history = history
        (updates, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func configure(sessionKey: String?, sendAlbumArtist: Bool) async {
        let changed = sessionKey != self.sessionKey
        self.sessionKey = sessionKey
        self.sendAlbumArtist = sendAlbumArtist
        if changed {
            status = sessionKey == nil ? .notConnected : .idle
            backoff = Self.minBackoff
            await publish()
            if sessionKey != nil { await flush() }
        }
    }

    public func enqueue(_ scrobble: Scrobble) async {
        do {
            try await queue.enqueue(scrobble)
            await history.record(scrobble, status: .queued)
        } catch {
            log.error("Could not persist scrobble: \(error.localizedDescription, privacy: .public)")
        }
        await publish()
        await flush()
    }

    /// Fire-and-forget; Last.fm says failed Now Playing requests must not be retried.
    public func nowPlaying(_ track: Track) async {
        guard let sessionKey else { return }
        do {
            try await client.updateNowPlaying(track, sessionKey: sessionKey, sendAlbumArtist: sendAlbumArtist)
        } catch let error as LastFMError where error.isInvalidSession {
            await sessionRevoked()
        } catch {
            log.info("Now Playing failed (not retried): \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends everything queued, in batches of 50. Safe to call any time (e.g. network came back).
    public func flush() async {
        guard !isFlushing, let sessionKey else { return }
        if case .needsReconnect = status { return }
        isFlushing = true
        defer { isFlushing = false }
        retryTask?.cancel()
        retryTask = nil

        while true {
            let batch = await queue.nextBatch()
            guard !batch.isEmpty else { break }
            status = .sending
            await publish()
            do {
                let outcomes = try await client.scrobble(batch, sessionKey: sessionKey, sendAlbumArtist: sendAlbumArtist)
                for (scrobble, outcome) in zip(batch, outcomes) {
                    if outcome.isAccepted {
                        await history.record(scrobble, status: .sent)
                    } else {
                        lastIgnored = "\(scrobble.track.title): \(outcome.reason)"
                        log.notice("Scrobble ignored: \(outcome.reason, privacy: .public)")
                        await history.record(scrobble, status: .ignored(outcome.reason))
                    }
                }
                try? await queue.remove(ids: Set(batch.map(\.id)))
                backoff = Self.minBackoff
            } catch let error as LastFMError where error.isInvalidSession {
                await sessionRevoked()
                return
            } catch let error as LastFMError where error.isRetryable {
                scheduleRetry(reason: error.description)
                await publish()
                return
            } catch {
                // Malformed request: retrying will never help. Drop the batch, keep a record.
                log.error("Dropping \(batch.count) scrobble(s): \(String(describing: error), privacy: .public)")
                for scrobble in batch {
                    await history.record(scrobble, status: .failed(String(describing: error)))
                }
                try? await queue.remove(ids: Set(batch.map(\.id)))
            }
        }
        status = .idle
        await publish()
    }

    private func scheduleRetry(reason: String) {
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        status = .retrying(at: Date().addingTimeInterval(delay), reason: reason)
        log.info("Scrobble submit failed (\(reason, privacy: .public)); retrying in \(Int(delay))s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.retryFired()
        }
    }

    private func retryFired() async {
        // Clear first: flush() cancels a pending retryTask, and cancelling the task we're
        // running in would make URLSession abort the very request we're about to send.
        retryTask = nil
        await flush()
    }

    private func sessionRevoked() async {
        status = .needsReconnect
        await publish()
    }

    public func publishCurrent() async {
        await publish()
    }

    private func publish() async {
        let snapshot = Snapshot(
            status: status,
            queued: await queue.count,
            history: await history.entries,
            lastIgnored: lastIgnored
        )
        continuation.yield(snapshot)
    }
}
