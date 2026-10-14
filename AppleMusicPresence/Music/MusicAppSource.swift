import AMPCore
import AppKit
import os

/// Produces `PlayerSnapshot`s for Apple Music.
///
/// - Music.app posts `com.apple.Music.playerInfo` on play/pause/track change. It often sends two
///   in a row ~20–100 ms apart (e.g. Paused then Playing), so refreshes are debounced.
/// - Seeks and repeat-one restarts post *nothing*, so the playhead is polled every 5 s while playing.
/// - Music launching/quitting and the Mac sleeping/waking come from NSWorkspace.
final class MusicAppSource {
    enum Access: Equatable {
        case unknown
        case granted
        case denied
    }

    static let musicBundleID = "com.apple.Music"
    static let pollInterval: TimeInterval = 5
    static let debounce: Duration = .milliseconds(150)

    var onSnapshot: ((PlayerSnapshot) -> Void)?
    var onAccessChange: ((Access) -> Void)?
    var onSleep: (() -> Void)?

    private(set) var access: Access = .unknown {
        didSet { if access != oldValue { onAccessChange?(access) } }
    }

    private let scripting = MusicScripting()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private let log = Logger(subsystem: AMPLog.subsystem, category: "music")

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).isEmpty
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.Music.playerInfo")) { source, _ in
            source.scheduleRefresh()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { source, bundleID in
            if bundleID == Self.musicBundleID { source.scheduleRefresh(after: .seconds(1)) }
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { source, bundleID in
            if bundleID == Self.musicBundleID { source.emitStopped() }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { source, _ in
            source.stopPolling()
            source.onSleep?()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { source, _ in
            source.scheduleRefresh(after: .seconds(2))
        }

        scheduleRefresh(after: .zero)
    }

    /// Re-read state soon, coalescing bursts of notifications into one Apple Event.
    func scheduleRefresh(after delay: Duration = MusicAppSource.debounce) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard isMusicRunning else {
            emitStopped()
            return
        }
        do {
            let snapshot = try scripting.snapshot()
            access = .granted
            onSnapshot?(snapshot)
            snapshot.state == .playing ? startPolling() : stopPolling()
        } catch .notAuthorized {
            log.error("Not allowed to control Music (Automation permission denied)")
            access = .denied
            stopPolling()
        } catch .notRunning {
            emitStopped()
        } catch {
            log.error("Reading Music state failed: \(String(describing: error), privacy: .public)")
        }
    }

    func artwork() -> NSImage? {
        guard isMusicRunning, access == .granted else { return nil }
        return scripting.artwork()
    }

    private func emitStopped() {
        stopPolling()
        onSnapshot?(PlayerSnapshot(state: .stopped, track: nil, position: nil, at: Date()))
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1 // let macOS coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// The handler receives the bundle ID of the app the notification is about, if any.
    /// (`Notification` itself isn't Sendable, so it can't cross onto the main actor.)
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (MusicAppSource, String?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let bundleID = Self.bundleID(of: note)
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, bundleID)
            }
        }
        observers.append((center, token))
    }

    nonisolated static func bundleID(of note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    isolated deinit {
        for (center, token) in observers { center.removeObserver(token) }
        pollTimer?.invalidate()
    }
}
