import AMPCore
import Foundation

/// Scrobbles waiting to be sent, persisted so nothing is lost across quits, crashes or offline periods.
/// Sent in order, oldest first, as Last.fm asks.
public actor ScrobbleQueue {
    private let fileURL: URL
    private var items: [Scrobble] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        items = (try? JSONFile.read([Scrobble].self, from: fileURL)) ?? []
    }

    public var count: Int { items.count }

    public func enqueue(_ scrobble: Scrobble) throws {
        items.append(scrobble)
        try save()
    }

    public func nextBatch(limit: Int = 50) -> [Scrobble] {
        Array(items.prefix(limit))
    }

    public func remove(ids: Set<UUID>) throws {
        items.removeAll { ids.contains($0.id) }
        try save()
    }

    private func save() throws {
        try JSONFile.write(items, to: fileURL)
    }
}

/// The last N scrobble attempts, for the "Recent" list in the menu. A fixed-size ring.
public actor ScrobbleHistory {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public enum Status: Codable, Sendable, Equatable {
            case queued
            case sent
            case ignored(String)
            case failed(String)
        }

        public var id: UUID
        public var track: Track
        public var timestamp: Date
        public var status: Status
    }

    public static let capacity = 50

    private let fileURL: URL
    private(set) public var entries: [Entry] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        entries = (try? JSONFile.read([Entry].self, from: fileURL)) ?? []
    }

    /// Inserts or updates the entry for `scrobble`, newest first.
    public func record(_ scrobble: Scrobble, status: Entry.Status) {
        if let index = entries.firstIndex(where: { $0.id == scrobble.id }) {
            entries[index].status = status
        } else {
            entries.insert(Entry(id: scrobble.id, track: scrobble.track, timestamp: scrobble.timestamp, status: status), at: 0)
            if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        }
        try? JSONFile.write(entries, to: fileURL)
    }
}
