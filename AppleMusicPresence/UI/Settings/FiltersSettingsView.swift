import AMPCore
import SwiftUI

struct FiltersSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.settings.ignoreRules.isEmpty {
                    Text("No filters. Everything is shared and scrobbled.")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.settings.ignoreRules) { $rule in
                    HStack {
                        Picker("", selection: $rule.field) {
                            ForEach(IgnoreRule.Field.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Picker("", selection: $rule.match) {
                            Text("contains").tag(IgnoreRule.Match.contains)
                            Text("is").tag(IgnoreRule.Match.equals)
                            Text("matches regex").tag(IgnoreRule.Match.regex)
                        }
                        .labelsHidden().fixedSize()
                        TextField("value", text: $rule.value)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $rule.scope) {
                            Text("Both").tag(IgnoreRule.Scope.both)
                            Text("Discord").tag(IgnoreRule.Scope.presence)
                            Text("Last.fm").tag(IgnoreRule.Scope.scrobbling)
                        }
                        .labelsHidden().fixedSize()
                        Button {
                            model.settings.ignoreRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add filter") {
                    model.settings.ignoreRules.append(IgnoreRule())
                }
            } header: {
                Text("Don't share or scrobble tracks where…")
            } footer: {
                Text("Matching ignores case and accents. “Discord” hides the presence only; “Last.fm” skips scrobbling only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
