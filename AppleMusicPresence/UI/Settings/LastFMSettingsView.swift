import AMPCore
import SwiftUI

struct LastFMSettingsView: View {
    @Bindable var model: AppModel

    private var scrobbling: Binding<ScrobbleSettings> { $model.settings.scrobbling }
    private var rules: ScrobbleSettings { model.settings.scrobbling }

    var body: some View {
        Form {
            Section("Account") {
                account
            }

            Section {
                Toggle("Scrobble to Last.fm", isOn: scrobbling.enabled)
                Toggle("Show “Scrobbling now” on my profile", isOn: scrobbling.sendNowPlaying)
            }

            Section {
                LabeledContent("Scrobble after") {
                    HStack(spacing: 8) {
                        Slider(value: scrobbling.thresholdPercent, in: 1...100, step: 1)
                            .frame(width: 180)
                        TextField("", value: percentBinding, format: .number.precision(.fractionLength(0)))
                            .frame(width: 44)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Text("% of the track")
                    }
                }
                Toggle("…or after a fixed time, whichever comes first", isOn: scrobbling.capEnabled)
                if rules.capEnabled {
                    DurationField(title: "Time", seconds: scrobbling.capSeconds, range: 10...1200, step: 15)
                }
                DurationField(title: "Minimum track length", seconds: scrobbling.minTrackLength, range: 0...600, step: 5)
            } header: {
                Text("When does a play count?")
            } footer: {
                Text(ruleSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Submit", selection: scrobbling.submitTiming) {
                    Text("As soon as the threshold is reached").tag(SubmitTiming.atThreshold)
                    Text("When the track ends or is skipped").tag(SubmitTiming.atTrackEnd)
                }
                .pickerStyle(.radioGroup)
                Toggle("Scrobble repeats of the same track", isOn: scrobbling.scrobbleRepeats)
                Toggle("Send album artist", isOn: scrobbling.sendAlbumArtist)
            } footer: {
                Text(rules.submitTiming == .atThreshold
                     ? "Counts even if you quit or skip later. Only listening time counts; seeking and pauses don't."
                     : "Lets you skip (or pause scrobbling) before the end to avoid scrobbling a track.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Queue") {
                LabeledContent("Waiting to be sent", value: "\(model.scrobbleStatus.queued)")
                if model.scrobbleStatus.queued > 0 {
                    Button("Send now", action: { model.flushScrobbles() })
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var account: some View {
        if !model.lastFMConfigured {
            Text("No Last.fm API key was configured at build time. Add LASTFM_API_KEY and LASTFM_SHARED_SECRET to Config/Secrets.xcconfig and rebuild.")
                .foregroundStyle(.secondary)
        } else if let session = model.lastFMSession {
            LabeledContent("Connected as") {
                HStack {
                    Link(session.username, destination: URL(string: "https://www.last.fm/user/\(session.username)")!)
                    Button("Disconnect", role: .destructive, action: { model.disconnectLastFM() })
                }
            }
            if model.scrobbleStatus.status == .needsReconnect {
                HStack {
                    Text("Last.fm rejected the session. Reconnect to resume.").foregroundStyle(.red)
                    Button("Reconnect", action: { model.connectLastFM() })
                }
            }
        } else {
            switch model.lastFMAuth {
            case .idle:
                HStack {
                    Text("Not connected")
                    Spacer()
                    Button("Connect Last.fm…", action: { model.connectLastFM() })
                        .buttonStyle(.borderedProminent)
                }
            case .waitingForApproval:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Click “Yes, allow access” in your browser…")
                    Spacer()
                    Button("Cancel", action: { model.cancelLastFMConnect() })
                }
            case .failed(let message):
                VStack(alignment: .leading) {
                    Text(message).foregroundStyle(.red)
                    Button("Try again", action: { model.connectLastFM() })
                }
            }
        }
    }

    private var percentBinding: Binding<Double> {
        Binding(get: { rules.thresholdPercent }, set: { model.settings.scrobbling.thresholdPercent = min(max($0, 1), 100) })
    }

    private var ruleSummary: String {
        let percent = Int(rules.thresholdPercent)
        var text = "A track counts after you've listened to \(percent)% of it"
        if rules.capEnabled { text += " or \(rules.capSeconds.clockString), whichever comes first" }
        text += ". Tracks shorter than \(rules.minTrackLength.clockString) are never scrobbled."
        let official = rules.thresholdPercent == 50 && rules.capEnabled && rules.capSeconds == 240 && rules.minTrackLength == 30
        if official { text += " (Last.fm's official rule.)" }
        return text
    }
}
