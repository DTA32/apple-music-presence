import DiscordRPC
import SwiftUI

/// An approximation of how Discord renders the activity on your profile.
struct PresencePreview: View {
    let activity: Activity
    var appName = "Apple Music"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    if let details = activity.details {
                        Text(details).font(.callout.weight(.semibold)).lineLimit(1)
                            .underline(activity.detailsURL != nil)
                    }
                    if let state = activity.state {
                        Text(state).font(.callout).lineLimit(1)
                            .underline(activity.stateURL != nil)
                    }
                    if let largeText = activity.assets?.largeText {
                        Text(largeText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let timestamps = activity.timestamps, let start = timestamps.start, let end = timestamps.end {
                        ProgressRow(start: start, end: end).padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }

            if let buttons = activity.buttons {
                ForEach(buttons, id: \.label) { button in
                    Text(button.label)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)))
                }
            }

            Text("Member list: \(memberListText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var verb: String { activity.type == 0 ? "Playing" : "Listening to" }

    private var header: String { "\(verb) \(appName)".uppercased() }

    private var memberListText: String {
        let subject = switch activity.statusDisplayType {
        case 1: activity.state ?? appName
        case 2: activity.details ?? appName
        default: appName
        }
        return "\(verb) \(subject)"
    }

    @ViewBuilder private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = activity.assets?.largeImage, image.hasPrefix("http"), let url = URL(string: image) {
                    AsyncImage(url: url) { phase in
                        if let loaded = phase.image { loaded.resizable() } else { placeholder }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if activity.assets?.smallImage != nil {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, .black)
                    .offset(x: 4, y: 4)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.pink, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.title).foregroundStyle(.white)
        }
    }
}

private struct ProgressRow: View {
    let start: Int64
    let end: Int64

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.timeIntervalSince1970 * 1000
            let total = Double(end - start) / 1000
            let elapsed = min(max((now - Double(start)) / 1000, 0), total)
            VStack(spacing: 2) {
                ProgressView(value: elapsed, total: max(total, 1))
                    .progressViewStyle(.linear)
                HStack {
                    Text(elapsed.clockString)
                    Spacer()
                    Text(total.clockString)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}
