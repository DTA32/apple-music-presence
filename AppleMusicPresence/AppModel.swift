import AMPCore
import AMPPresence
import AppKit
import Artwork
import DiscordRPC
import LastFM
import Network
import Observation
import os

/// The app's single coordinator. It owns every service, routes playback events to presence and
/// scrobbling, and exposes the state the menu and Settings window render.
///
/// Data flow: MusicAppSource → PlaybackEngine → (PresenceBuilder → DiscordIPCClient)
///                                            → (ScrobbleTracker → ScrobbleSubmitter → Last.fm)
@Observable
final class AppModel {
    enum LastFMAuthState: Equatable {
        case idle
        case waitingForApproval
        case failed(String)
    }

    enum HotkeyAction: UInt32, CaseIterable {
        case toggleScrobbling = 1
        case togglePresence = 2
    }

    // MARK: - Settings

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            settingsDidChange(from: oldValue)
        }
    }

    // MARK: - Observable state

    private(set) var track: Track?
    private(set) var playerState: PlayerState = .stopped
    private(set) var artworkImage: NSImage?
    private(set) var artworkInfo: ArtworkInfo?
    private(set) var musicAccess: MusicAppSource.Access = .unknown
    private(set) var discordStatus: DiscordIPCClient.Status = .stopped
    private(set) var lastFMSession: LastFMSession?
    private(set) var lastFMAuth: LastFMAuthState = .idle
    private(set) var scrobbleStatus = ScrobbleSubmitter.Snapshot(status: .notConnected, queued: 0, history: [], lastIgnored: nil)
    private(set) var scrobblePause: PauseState = .active
    private(set) var presencePause: PauseState = .active
    private(set) var hotkeyErrors: [HotkeyAction: String] = [:]
    /// What we last asked Discord to show; nil = cleared.
    private(set) var currentActivity: Activity?
    private(set) var launchAtLogin = LaunchAtLogin.isEnabled

    let lastFMConfigured = AppConfig.lastFMCredentials.isConfigured
    var discordClientID: String {
        let override = settings.presence.clientIDOverride.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? AppConfig.discordClientID : override
    }

    // MARK: - Services

    @ObservationIgnored private var engine = PlaybackEngine()
    @ObservationIgnored private var tracker = ScrobbleTracker()
    @ObservationIgnored private let music = MusicAppSource()
    @ObservationIgnored private let discord = DiscordIPCClient()
    @ObservationIgnored private let artworkResolver: ArtworkResolver
    @ObservationIgnored private let lastFM: LastFMClient
    @ObservationIgnored private let submitter: ScrobbleSubmitter
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let log = Logger.app
    @ObservationIgnored private var activityPipe: OrderedPipe<Activity?>!
    @ObservationIgnored private var scrobblePipe: OrderedPipe<ScrobbleAction>!

    // Presence anchor: playhead position at a moment, captured on playback events only, so the
    // progress bar timestamps don't jitter with every 5 s poll.
    @ObservationIgnored private var anchorPosition: TimeInterval = 0
    @ObservationIgnored private var anchorDate = Date.distantPast
    @ObservationIgnored private var pausedSince: Date?

    @ObservationIgnored private var thresholdTask: Task<Void, Never>?
    @ObservationIgnored private var presenceRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var pauseExpiryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var listenerTasks: [Task<Void, Never>] = []

    private static let settingsKey = "settings"
    private static let scrobblePauseKey = "pause.scrobbling"
    private static let presencePauseKey = "pause.presence"
    private static let sessionAccount = "lastfm-session"

    init() {
        settings = Self.loadSettings()
        scrobblePause = Self.loadPause(Self.scrobblePauseKey)
        presencePause = Self.loadPause(Self.presencePauseKey)

        let dir = AppConfig.supportDirectory
        artworkResolver = ArtworkResolver(cacheURL: dir.appending(path: "artwork-cache.json"))
        lastFM = LastFMClient(credentials: AppConfig.lastFMCredentials)
        submitter = ScrobbleSubmitter(
            client: lastFM,
            queue: ScrobbleQueue(fileURL: dir.appending(path: "queue.json")),
            history: ScrobbleHistory(fileURL: dir.appending(path: "history.json"))
        )
        lastFMSession = Self.loadSession()

        start()
    }

    private func start() {
        let discord = discord
        let submitter = submitter
        activityPipe = OrderedPipe { await discord.setActivity($0) }
        scrobblePipe = OrderedPipe { action in
            switch action {
            case .nowPlaying(let track): await submitter.nowPlaying(track)
            case .scrobble(let scrobble): await submitter.enqueue(scrobble)
            }
        }

        listenerTasks.append(Task { [weak self] in
            for await status in discord.statusUpdates {
                Logger.app.info("Discord: \(String(describing: status), privacy: .public)")
                self?.discordStatus = status
            }
        })
        listenerTasks.append(Task { [weak self] in
            for await snapshot in submitter.updates { self?.scrobbleStatus = snapshot }
        })

        music.onSnapshot = { [weak self] in self?.ingest($0) }
        music.onAccessChange = { [weak self] access in
            Logger.app.info("Music access: \(String(describing: access), privacy: .public)")
            self?.musicAccess = access
        }
        music.onSleep = { [weak self] in self?.handleSleep() }
        music.start()

        watchDiscordLaunches()
        watchNetwork()
        configureDiscord()
        configureSubmitter()
        registerHotkeys()
        schedulePauseExpiry()
    }

    // MARK: - Playback

    private func ingest(_ snapshot: PlayerSnapshot) {
        let previousTrackID = engine.track?.persistentID
        let events = engine.ingest(snapshot)
        track = engine.track
        playerState = engine.state
        guard !events.isEmpty else { return }

        for event in events {
            log.info("Playback: \(String(describing: event), privacy: .public)")
            switch event {
            case let .started(_, position, playing, at):
                anchorPosition = position
                anchorDate = at
                pausedSince = playing ? nil : at
            case let .resumed(position, at):
                anchorPosition = position
                anchorDate = at
                pausedSince = nil
            case let .seeked(position, at):
                anchorPosition = position
                anchorDate = at
            case let .paused(position, at):
                anchorPosition = position
                anchorDate = at
                pausedSince = at
            case .stopped:
                pausedSince = nil
            }
            handleScrobbling(event)
        }

        if engine.track?.persistentID != previousTrackID {
            trackDidChange()
        }
        updatePresence()
    }

    private func trackDidChange() {
        artworkInfo = nil
        guard let track = engine.track else {
            log.info("Nothing playing")
            artworkImage = nil
            return
        }
        log.info("Track: \(track.artist, privacy: .public) – \(track.title, privacy: .public) [\(String(describing: self.engine.state), privacy: .public)]")
        artworkImage = music.artwork()
        let resolver = artworkResolver
        Task { [weak self] in
            let info = await resolver.lookup(track)
            guard let self, self.engine.track?.persistentID == track.persistentID else { return }
            self.artworkInfo = info
            self.updatePresence()
        }
    }

    /// Going to sleep: count the track as paused so listened time doesn't accrue overnight.
    private func handleSleep() {
        guard engine.state == .playing, let track = engine.track else { return }
        let now = Date()
        ingest(PlayerSnapshot(state: .paused, track: track, position: engine.expectedPosition(at: now), at: now))
    }

    /// Re-read Music now (menu opened, permission granted, …).
    func refreshMusic() {
        music.refresh()
    }

    // MARK: - Presence

    private func updatePresence() {
        presenceRecheckTask?.cancel()
        presenceRecheckTask = nil
        let now = Date()
        let decision = PresenceBuilder.decide(presenceInput(now: now), settings: settings.presence, now: now)

        let activity: Activity?
        switch decision {
        case .clear:
            activity = nil
        case .show(let shown):
            activity = shown
        case .showUntil(let shown, let until):
            activity = shown
            presenceRecheckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 0.1))
                guard !Task.isCancelled else { return }
                self?.updatePresence()
            }
        }
        currentActivity = activity
        // Always forward: the client drops duplicates itself, and re-sends after reconnecting.
        activityPipe.send(activity)
    }

    private func presenceInput(now: Date) -> PresenceInput {
        PresenceInput(
            track: engine.track,
            state: engine.state,
            position: anchorPosition,
            positionDate: anchorDate,
            pausedSince: pausedSince,
            artwork: artworkInfo,
            isPresencePaused: presencePause.isPaused(at: now),
            isIgnored: engine.track.map { settings.ignoreRules.ignores($0, for: .presence) } ?? false
        )
    }

    /// The activity as it would look while playing, for the Settings preview.
    /// Uses the current track if there is one, otherwise a sample.
    var previewActivity: Activity {
        let sample = Track(persistentID: "preview", title: "Love Me Like a Friend", artist: "Fly By Midnight", album: "Happy About Everything Else...", duration: 202, genre: "Pop", year: 2017)
        let previewTrack = track ?? sample
        let now = Date()
        let input = PresenceInput(
            track: previewTrack, state: .playing,
            position: track == nil ? 63 : engine.expectedPosition(at: now), positionDate: now,
            pausedSince: nil, artwork: track == nil ? nil : artworkInfo,
            isPresencePaused: false, isIgnored: false
        )
        return PresenceBuilder.activity(for: input, track: previewTrack, settings: settings.presence, playing: true)
    }

    private func configureDiscord() {
        let discord = discord
        let enabled = settings.presence.enabled
        let clientID = discordClientID
        Task {
            if enabled {
                await discord.start(clientID: clientID)
            } else {
                await discord.stop()
            }
        }
        updatePresence()
    }

    private func watchDiscordLaunches() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard MusicAppSource.bundleID(of: note) == "com.hnc.Discord" else { return }
            MainActor.assumeIsolated {
                // Discord creates its IPC socket a few seconds after launch.
                let discord = self?.discord
                Task {
                    for delay in [3.0, 8.0] {
                        try? await Task.sleep(for: .seconds(delay))
                        await discord?.reconnectNow()
                    }
                }
            }
        }
        _ = token // lives for the app's lifetime
    }

    // MARK: - Scrobbling

    private var scrobbleContext: ScrobbleTracker.Context {
        let rules = settings.ignoreRules
        return ScrobbleTracker.Context(
            settings: settings.scrobbling,
            // Not connected = nothing to scrobble to; don't build up a queue that may never be sent.
            isPaused: scrobblePause.isPaused(at: Date()) || lastFMSession == nil,
            isIgnored: { rules.ignores($0, for: .scrobbling) }
        )
    }

    private func handleScrobbling(_ event: PlaybackEvent) {
        perform(tracker.handle(event, context: scrobbleContext))
        rescheduleThreshold()
    }

    private func perform(_ actions: [ScrobbleAction]) {
        for action in actions {
            if case .scrobble(let scrobble) = action {
                log.info("Scrobbling \(scrobble.track.artist, privacy: .public) – \(scrobble.track.title, privacy: .public)")
            }
            scrobblePipe.send(action)
        }
    }

    private func rescheduleThreshold() {
        thresholdTask?.cancel()
        thresholdTask = nil
        guard let due = tracker.nextDecisionDate(context: scrobbleContext) else { return }
        thresholdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.perform(self.tracker.tick(at: Date(), context: self.scrobbleContext))
            self.rescheduleThreshold()
        }
    }

    /// Listened time vs. threshold for the current play, for the menu.
    var scrobbleProgress: (listened: TimeInterval, threshold: TimeInterval)? {
        tracker.progress(at: Date(), settings: settings.scrobbling)
    }

    private func configureSubmitter() {
        let submitter = submitter
        let key = lastFMSession?.key
        let sendAlbumArtist = settings.scrobbling.sendAlbumArtist
        Task {
            await submitter.configure(sessionKey: key, sendAlbumArtist: sendAlbumArtist)
            await submitter.publishCurrent() // so the menu has queue + history even when nothing changed
        }
    }

    func flushScrobbles() {
        let submitter = submitter
        Task { await submitter.flush() }
    }

    private func watchNetwork() {
        let submitter = submitter
        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { await submitter.flush() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "amp.network"))
    }

    // MARK: - Last.fm account

    /// Desktop auth: get a token, open the approval page, poll until the user clicks Allow.
    func connectLastFM() {
        authTask?.cancel()
        lastFMAuth = .waitingForApproval
        let client = lastFM
        authTask = Task { [weak self] in
            do {
                let token = try await client.getToken()
                NSWorkspace.shared.open(client.authorizationURL(token: token))
                let deadline = Date().addingTimeInterval(10 * 60)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    do {
                        let session = try await client.getSession(token: token)
                        self?.didConnect(session)
                        return
                    } catch let error as LastFMError where error.isUnauthorizedToken {
                        continue // not approved yet
                    }
                }
                self?.lastFMAuth = .failed("Timed out waiting for approval. Try again.")
            } catch is CancellationError {
                self?.lastFMAuth = .idle
            } catch {
                self?.lastFMAuth = .failed(String(describing: error))
            }
        }
    }

    func cancelLastFMConnect() {
        authTask?.cancel()
        authTask = nil
        lastFMAuth = .idle
    }

    private func didConnect(_ session: LastFMSession) {
        if let data = try? JSONEncoder().encode(session) {
            do {
                try Keychain.save(data, account: Self.sessionAccount)
            } catch {
                log.error("Saving Last.fm session to Keychain failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        lastFMSession = session
        lastFMAuth = .idle
        configureSubmitter()
        rescheduleThreshold()
        NSApp.activate()
    }

    func disconnectLastFM() {
        Keychain.delete(account: Self.sessionAccount)
        lastFMSession = nil
        configureSubmitter()
        rescheduleThreshold()
    }

    // MARK: - Pausing

    func setPresencePause(_ state: PauseState) {
        presencePause = state
        Self.savePause(state, key: Self.presencePauseKey)
        schedulePauseExpiry()
        updatePresence()
    }

    func setScrobblePause(_ state: PauseState) {
        scrobblePause = state
        Self.savePause(state, key: Self.scrobblePauseKey)
        schedulePauseExpiry()
        rescheduleThreshold()
    }

    func togglePresencePause() {
        let pausing = !presencePause.isPaused(at: Date())
        setPresencePause(pausing ? .paused(until: nil) : .active)
        if settings.showPauseBanners { Banner.show(pausing ? "Discord presence paused" : "Discord presence resumed") }
    }

    func toggleScrobblePause() {
        let pausing = !scrobblePause.isPaused(at: Date())
        setScrobblePause(pausing ? .paused(until: nil) : .active)
        if settings.showPauseBanners { Banner.show(pausing ? "Scrobbling paused" : "Scrobbling resumed") }
    }

    /// Flip timed pauses back to active when they expire, so the icon and presence update.
    private func schedulePauseExpiry() {
        for (key, state) in [(Self.presencePauseKey, presencePause), (Self.scrobblePauseKey, scrobblePause)] {
            pauseExpiryTasks[key]?.cancel()
            guard let until = state.expiry else { continue }
            pauseExpiryTasks[key] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 0.5))
                guard !Task.isCancelled, let self else { return }
                if key == Self.presencePauseKey { self.setPresencePause(.active) } else { self.setScrobblePause(.active) }
            }
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        var errors: [HotkeyAction: String] = [:]
        let center = HotKeyCenter.shared
        errors[.toggleScrobbling] = center.register(id: HotkeyAction.toggleScrobbling.rawValue, combo: settings.hotkeys.toggleScrobbling) { [weak self] in
            self?.toggleScrobblePause()
        }
        errors[.togglePresence] = center.register(id: HotkeyAction.togglePresence.rawValue, combo: settings.hotkeys.togglePresence) { [weak self] in
            self?.togglePresencePause()
        }
        hotkeyErrors = errors
    }

    // MARK: - Settings plumbing

    private func settingsDidChange(from old: AppSettings) {
        if old.presence.enabled != settings.presence.enabled || old.presence.clientIDOverride != settings.presence.clientIDOverride {
            configureDiscord()
        } else if old.presence != settings.presence || old.ignoreRules != settings.ignoreRules {
            updatePresence()
        }
        if old.scrobbling != settings.scrobbling || old.ignoreRules != settings.ignoreRules {
            if old.scrobbling.sendAlbumArtist != settings.scrobbling.sendAlbumArtist { configureSubmitter() }
            rescheduleThreshold()
        }
        if old.hotkeys != settings.hotkeys { registerHotkeys() }
        if settings.showPauseBanners && !old.showPauseBanners {
            Task { _ = await Banner.requestPermission() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
        } catch {
            log.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func exportSettings() throws -> Data {
        try SettingsCodec.encode(settings)
    }

    func importSettings(_ data: Data) throws {
        settings = try SettingsCodec.decode(data)
    }

    func resetSettings() {
        settings = AppSettings()
    }

    private func saveSettings() {
        guard let data = try? SettingsCodec.encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else { return AppSettings() }
        do {
            return try SettingsCodec.decode(data)
        } catch {
            Logger.app.error("Stored settings unreadable, using defaults: \(error.localizedDescription, privacy: .public)")
            return AppSettings()
        }
    }

    private static func loadPause(_ key: String) -> PauseState {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PauseState.self, from: data),
              state.isPaused(at: Date())
        else { return .active }
        return state
    }

    private static func savePause(_ state: PauseState, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: key)
    }

    private static func loadSession() -> LastFMSession? {
        Keychain.load(account: sessionAccount).flatMap { try? JSONDecoder().decode(LastFMSession.self, from: $0) }
    }
}
