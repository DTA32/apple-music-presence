import AMPCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettingsView(model: model) }
            Tab("Discord", systemImage: "person.wave.2") { DiscordSettingsView(model: model) }
            Tab("Last.fm", systemImage: "music.note.list") { LastFMSettingsView(model: model) }
            Tab("Filters", systemImage: "line.3.horizontal.decrease.circle") { FiltersSettingsView(model: model) }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettingsView(model: model) }
        }
        .frame(width: 560, height: 620)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if LaunchAtLogin.needsApproval {
                    Text("Approve it in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HotkeyRow(title: "Pause / resume scrobbling", combo: $model.settings.hotkeys.toggleScrobbling, error: model.hotkeyErrors[.toggleScrobbling])
                HotkeyRow(title: "Pause / resume Discord presence", combo: $model.settings.hotkeys.togglePresence, error: model.hotkeyErrors[.togglePresence])
                Toggle("Show a notification when a shortcut pauses or resumes", isOn: $model.settings.showPauseBanners)
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Shortcuts work in any app. The menu bar icon also changes while something is paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRow: View {
    let title: String
    @Binding var combo: KeyCombo?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                ShortcutRecorder(combo: $combo)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @Bindable var model: AppModel
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("Client ID override", text: $model.settings.presence.clientIDOverride, prompt: Text(AppConfig.discordClientID.isEmpty ? "none bundled" : AppConfig.discordClientID))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Discord application")
            } footer: {
                Text("The Discord application's name is what appears after “Listening to”. Leave empty to use the one bundled at build time.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Settings file") {
                HStack {
                    Button("Export…", action: export)
                    Button("Import…", action: importSettings)
                    Spacer()
                    Button("Reset to defaults", role: .destructive) { model.resetSettings() }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Data") {
                LabeledContent("Queue, history, artwork cache") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppConfig.supportDirectory])
                    }
                }
                LabeledContent("Logs") {
                    Text("log stream --predicate 'subsystem == \"\(AppConfig.bundleID)\"'")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AppleMusicPresence-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportSettings().write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)"
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importSettings(Data(contentsOf: url))
            message = "Imported \(url.lastPathComponent)"
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Shared controls

/// Seconds, edited as a number with a stepper and shown as m:ss.
struct DurationField: View {
    let title: String
    @Binding var seconds: TimeInterval
    let range: ClosedRange<TimeInterval>
    var step: TimeInterval = 5

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: clamped, format: .number.precision(.fractionLength(0)))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                Text("s (\(seconds.clockString))").foregroundStyle(.secondary).monospacedDigit()
                Stepper("", value: clamped, in: range, step: step).labelsHidden()
            }
        }
    }

    private var clamped: Binding<TimeInterval> {
        Binding(get: { seconds }, set: { seconds = min(max($0, range.lowerBound), range.upperBound) })
    }
}
