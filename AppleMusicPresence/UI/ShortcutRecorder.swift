import AMPCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, press a key combination, done. Esc cancels, ⌫ clears.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? (hint ?? "Press shortcut…") : (combo?.display ?? "Record shortcut"))
                    .frame(minWidth: 110)
                    .monospaced(!isRecording && combo != nil)
            }
            if combo != nil && !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        hint = nil
        HotKeyCenter.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil // swallow the key press while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotKeyCenter.shared.setSuspended(false)
    }

    private func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plain:
            stop()
        case kVK_Delete where plain, kVK_ForwardDelete where plain:
            combo = nil
            stop()
        default:
            guard let recorded = KeyCombo(event: event) else { return }
            guard recorded.isAllowedBySystem else {
                hint = "Include ⌘ or ⌃"
                return
            }
            combo = recorded
            stop()
        }
    }
}
