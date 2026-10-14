import AMPCore
import Foundation
import LastFM
import os
import Security
import ServiceManagement
import UserNotifications

/// Values baked in at build time from Config/Secrets.xcconfig (via Info.plist).
enum AppConfig {
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.dta32.applemusicpresence"

    static var discordClientID: String { infoString("AMPDiscordClientID") }

    static var lastFMCredentials: LastFMCredentials {
        LastFMCredentials(apiKey: infoString("AMPLastFMAPIKey"), sharedSecret: infoString("AMPLastFMSharedSecret"))
    }

    /// ~/Library/Application Support/AppleMusicPresence
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "AppleMusicPresence", directoryHint: .isDirectory)
    }

    private static func infoString(_ key: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        // An unset build setting can survive as a literal "$(NAME)".
        return value.hasPrefix("$(") ? "" : value
    }
}

extension Logger {
    nonisolated static let app = Logger(subsystem: AMPLog.subsystem, category: "app")
}

/// Generic-password items in the login keychain, scoped to this app's bundle ID.
enum Keychain {
    static func save(_ data: Data, account: String) throws {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.bundleID,
            kSecAttrAccount as String: account,
        ]
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Optional banners for hotkey feedback ("Scrobbling paused").
enum Banner {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    static func show(_ title: String, body: String = "") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "amp.banner", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Delivers values to an async handler strictly in order, one at a time.
/// (Separate `Task { await actor.f() }` calls are not guaranteed to run in creation order.)
final class OrderedPipe<Value: Sendable> {
    private let continuation: AsyncStream<Value>.Continuation
    private let task: Task<Void, Never>

    init(_ handler: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
        self.continuation = continuation
        task = Task.detached {
            for await value in stream { await handler(value) }
        }
    }

    func send(_ value: Value) {
        continuation.yield(value)
    }

    isolated deinit {
        continuation.finish()
        task.cancel()
    }
}

extension TimeInterval {
    /// "3:05", "1:02:03"
    var clockString: String {
        let total = Int(self.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
