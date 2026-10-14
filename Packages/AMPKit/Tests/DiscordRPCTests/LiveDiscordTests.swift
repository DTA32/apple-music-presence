import DiscordRPC
import Foundation
import Testing

/// Talks to the real Discord desktop app. Opt-in:
///   AMP_LIVE_DISCORD=1 swift test --filter LiveDiscord                      (handshake rejection only)
///   AMP_LIVE_DISCORD=1 AMP_DISCORD_CLIENT_ID=<id> swift test --filter LiveDiscord   (also shows a presence for ~10 s)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AMP_LIVE_DISCORD"] == "1"))
struct LiveDiscordTests {
    @Test func invalidClientIDIsRejectedByDiscord() async throws {
        let client = DiscordIPCClient()
        await client.start(clientID: "1")
        let status = try await firstStatus(of: client) { if case .error = $0 { true } else { false } }
        print("Discord said:", status)
        await client.stop()
    }

    @Test func realClientIDConnectsAndShowsPresence() async throws {
        guard let id = ProcessInfo.processInfo.environment["AMP_DISCORD_CLIENT_ID"], !id.isEmpty else { return }
        let client = DiscordIPCClient()
        await client.start(clientID: id)
        let status = try await firstStatus(of: client) { if case .connected = $0 { true } else { false } }
        print("Connected:", status)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        await client.setActivity(Activity(
            type: 2, statusDisplayType: 1,
            details: "Live test from AMPKit", state: "Apple Music Presence",
            timestamps: .init(start: now, end: now + 180_000),
            assets: .init(largeImage: "logo", largeText: "Test")
        ))
        try await Task.sleep(for: .seconds(10))
        await client.stop()
    }

    private func firstStatus(of client: DiscordIPCClient, where predicate: @escaping @Sendable (DiscordIPCClient.Status) -> Bool) async throws -> DiscordIPCClient.Status {
        try await withThrowingTaskGroup(of: DiscordIPCClient.Status.self) { group in
            group.addTask {
                for await status in client.statusUpdates where predicate(status) { return status }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw DiscordIPCError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
