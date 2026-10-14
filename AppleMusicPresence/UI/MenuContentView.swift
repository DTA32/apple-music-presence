import AMPCore
import DiscordRPC
import LastFM
import SwiftUI

/// Menu bar icon. Changes with pause state so hotkey presses are visible at a glance.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let now = Date()
        let presencePaused = model.presencePause.isPaused(at: now)
        let scrobblingPaused = model.scrobblePause.isPaused(at: now)
        let symbol = switch (presencePaused, scrobblingPaused) {
        case (true, true): "pause.circle.fill"
        case (false, true): "pause.circle"
        case (true, false): "eye.slash"
        case (false, false): "music.note"
        }
        Image(systemName: symbol)
            .accessibilityLabel("Apple Music Presence")
    }
}

struct MenuContentView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var showRecent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowPlayingCard(model: model)

            if model.musicAccess == .denied {
                MusicAccessWarning(model: model)
            }

            Divider()

            ServiceRow(
                title: "Discord",
                status: discordStatusText,
                tint: discordTint,
                pause: model.presencePause,
                onPause: { model.setPresencePause($0) }
            )
            ServiceRow(
                title: "Last.fm",
                status: lastFMStatusText,
                tint: lastFMTint,
                pause: model.scrobblePause,
                onPause: { model.setScrobblePause($0) }
            )

            if let ignored = model.scrobbleStatus.lastIgnored {
                Label(ignored, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if !model.scrobbleStatus.history.isEmpty {
                DisclosureGroup(isExpanded: $showRecent) {
                    RecentScrobblesList(entries: Array(model.scrobbleStatus.history.prefix(10)))
                } label: {
                    Text("Recent scrobbles").font(.callout)
                }
            }

            Divider()

            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshMusic() }
    }

    private var discordStatusText: String {
        if !model.settings.presence.enabled { return "Off" }
        return switch model.discordStatus {
        case .stopped: "Off"
        case .notConfigured: "No Discord client ID configured"
        case .waitingForDiscord: "Waiting for Discord…"
        case .connected(let user): model.currentActivity == nil ? "Connected · not sharing" : "Sharing" + (user.map { " as \($0)" } ?? "")
        case .error(let message): message
        }
    }

    private var discordTint: Color {
        switch model.discordStatus {
        case .connected: model.currentActivity == nil ? .secondary : .green
        case .error, .notConfigured: .red
        default: .secondary
        }
    }

    private var lastFMStatusText: String {
        guard model.lastFMConfigured else { return "No Last.fm API key configured" }
        guard let session = model.lastFMSession else { return "Not connected" }
        if !model.settings.scrobbling.enabled { return "\(session.username) · scrobbling off" }
        let queued = model.scrobbleStatus.queued
        let suffix = queued > 0 ? " · \(queued) queued" : ""
        return switch model.scrobbleStatus.status {
        case .needsReconnect: "Session expired, reconnect in Settings"
        case .retrying(let at, _): "\(session.username)\(suffix) · retry \(at.formatted(.relative(presentation: .named)))"
        case .sending: "\(session.username) · sending…"
        default: session.username + suffix
        }
    }

    private var lastFMTint: Color {
        guard model.lastFMConfigured, model.lastFMSession != nil else { return .red }
        return switch model.scrobbleStatus.status {
        case .needsReconnect: .red
        case .retrying: .orange
        default: model.settings.scrobbling.enabled ? .green : .secondary
        }
    }
}

private struct NowPlayingCard: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let image = model.artworkImage {
                    Image(nsImage: image).resizable()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                if let track = model.track {
                    Text(track.title).font(.headline).lineLimit(1)
                    Text([track.artist, track.album].compactMap { $0 }.joined(separator: " — "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing playing").font(.headline)
                    Text(model.musicAccess == .denied ? "No access to Music" : "Play something in Apple Music")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusLine: String {
        var parts = [model.playerState == .playing ? "Playing" : "Paused"]
        if let progress = model.scrobbleProgress, model.lastFMSession != nil, model.settings.scrobbling.enabled {
            parts.append(progress.listened >= progress.threshold
                ? "scrobble threshold reached"
                : "scrobbles in \((progress.threshold - progress.listened).clockString)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct MusicAccessWarning: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Allow control of Music", systemImage: "lock")
                .font(.callout.bold())
            Text("Enable Apple Music Presence → Music in System Settings › Privacy & Security › Automation.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Automation Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                Button("Retry") { model.refreshMusic() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
    }
}

private struct ServiceRow: View {
    let title: String
    let status: String
    let tint: Color
    let pause: PauseState
    let onPause: (PauseState) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(isPaused ? Color.orange : tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.bold())
                Text(isPaused ? pausedText : status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if isPaused {
                Button("Resume") { onPause(.active) }.controlSize(.small)
            } else {
                Menu("Pause") {
                    Button("For 1 hour") { onPause(.paused(until: Date().addingTimeInterval(3600))) }
                    Button("Until tomorrow") { onPause(.paused(until: PauseState.tomorrow(after: Date()))) }
                    Button("Until I resume") { onPause(.paused(until: nil)) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }
        }
    }

    private var isPaused: Bool { pause.isPaused(at: Date()) }

    private var pausedText: String {
        if let until = pause.expiry {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "Paused"
    }
}

private struct RecentScrobblesList: View {
    let entries: [ScrobbleHistory.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(entry.status))
                        .foregroundStyle(color(entry.status))
                        .frame(width: 14)
                        .help(statusText(entry.status))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.track.title).font(.caption).lineLimit(1)
                        Text("\(entry.track.artist) · \(entry.timestamp.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func symbol(_ status: ScrobbleHistory.Entry.Status) -> String {
        switch status {
        case .queued: "clock"
        case .sent: "checkmark.circle"
        case .ignored: "exclamationmark.triangle"
        case .failed: "xmark.circle"
        }
    }

    private func color(_ status: ScrobbleHistory.Entry.Status) -> Color {
        switch status {
        case .queued: .secondary
        case .sent: .green
        case .ignored: .orange
        case .failed: .red
        }
    }

    private func statusText(_ status: ScrobbleHistory.Entry.Status) -> String {
        switch status {
        case .queued: "Queued"
        case .sent: "Scrobbled"
        case .ignored(let reason): "Ignored by Last.fm: \(reason)"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
