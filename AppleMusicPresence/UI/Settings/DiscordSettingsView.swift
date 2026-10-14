import AMPCore
import SwiftUI

struct DiscordSettingsView: View {
    @Bindable var model: AppModel

    private var presence: Binding<PresenceSettings> { $model.settings.presence }

    var body: some View {
        Form {
            Section {
                PresencePreview(activity: model.previewActivity)
                    .opacity(model.settings.presence.enabled ? 1 : 0.4)
            } footer: {
                Text(model.track == nil ? "Preview with a sample track. Play something to see your own." : "Preview of the current track while playing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Share what I'm listening to on Discord", isOn: presence.enabled)
                Picker("Activity type", selection: presence.activityType) {
                    Text("Listening to …").tag(PresenceActivityType.listening)
                    Text("Playing …").tag(PresenceActivityType.playing)
                }
                Picker("Member list shows", selection: presence.statusDisplay) {
                    Text("App name (“Apple Music”)").tag(StatusDisplay.appName)
                    Text("Second line (state)").tag(StatusDisplay.state)
                    Text("First line (details)").tag(StatusDisplay.details)
                }
            }

            Section {
                TextField("First line (details)", text: presence.detailsTemplate)
                TextField("Second line (state)", text: presence.stateTemplate)
                TextField("Album art tooltip", text: presence.largeTextTemplate)
            } header: {
                Text("Text")
            } footer: {
                Text("Placeholders: " + Template.placeholders.map { "{\($0)}" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Display") {
                Toggle("Show album art", isOn: presence.showArtwork)
                Toggle("Show progress bar", isOn: presence.showProgress)
                Toggle("Make title, artist and cover clickable", isOn: presence.clickableLinks)
                Picker("Button 1", selection: presence.button1) { buttonOptions }
                Picker("Button 2", selection: presence.button2) { buttonOptions }
            }

            Section {
                Picker("When playback is paused", selection: presence.pausedBehavior) {
                    Text("Clear immediately").tag(PausedBehavior.clearImmediately)
                    Text("Clear after a delay").tag(PausedBehavior.clearAfterDelay)
                    Text("Keep showing “Paused”").tag(PausedBehavior.keepShowing)
                }
                if model.settings.presence.pausedBehavior == .clearAfterDelay {
                    DurationField(title: "Delay", seconds: presence.pausedClearDelay, range: 5...3600)
                }
                if model.settings.presence.pausedBehavior != .clearImmediately {
                    TextField("Paused label", text: presence.pausedText)
                }
            } header: {
                Text("Paused")
            } footer: {
                Text("While shown as paused, the progress bar is hidden and a pause badge appears on the cover.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var buttonOptions: some View {
        Text("None").tag(PresenceButton.none)
        Text("Listen on Apple Music").tag(PresenceButton.appleMusic)
        Text("View on Last.fm").tag(PresenceButton.lastFM)
    }
}
