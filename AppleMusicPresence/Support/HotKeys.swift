import AMPCore
import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Old API, but still the supported way to register global shortcuts, and unlike global NSEvent
/// monitors or event taps it needs no Accessibility / Input Monitoring permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private static let signature: OSType = 0x414D_5048 // 'AMPH'

    private var actions: [UInt32: () -> Void] = [:]
    private var combos: [UInt32: KeyCombo] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var isSuspended = false

    /// Registers `combo` under `id`, replacing any previous registration.
    /// Returns a user-facing error message, or nil on success (or when `combo` is nil).
    @discardableResult
    func register(id: UInt32, combo: KeyCombo?, action: @escaping () -> Void) -> String? {
        unregister(id: id)
        guard let combo else { return nil }
        guard combo.isAllowedBySystem else { return "Shortcuts must include ⌘ or ⌃" }
        installHandlerIfNeeded()
        actions[id] = action
        combos[id] = combo
        return isSuspended ? nil : activate(id)
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
        combos[id] = nil
    }

    /// Temporarily release all shortcuts, e.g. while the user records a new one
    /// (otherwise pressing an existing combo would fire it instead of recording it).
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            for ref in refs.values { UnregisterEventHotKey(ref) }
            refs.removeAll()
        } else {
            for id in combos.keys { activate(id) }
        }
    }

    @discardableResult
    private func activate(_ id: UInt32) -> String? {
        guard let combo = combos[id] else { return nil }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        switch status {
        case noErr:
            refs[id] = ref
            return nil
        case OSStatus(eventHotKeyExistsErr):
            return "\(combo.display) is already used by another app"
        default:
            return "Couldn't register \(combo.display) (error \(status))"
        }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }
}

/// Carbon delivers hotkey events on the main thread. `nonisolated` because a C function pointer
/// can't carry actor isolation (the target defaults to MainActor).
nonisolated private func hotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(hotKeyID.id) }
    return noErr
}

extension KeyCombo {
    /// Builds a combo from a key press, or nil if it isn't a usable global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= KeyCombo.control; symbols += "⌃" }
        if flags.contains(.option) { carbon |= KeyCombo.option; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= KeyCombo.shift; symbols += "⇧" }
        if flags.contains(.command) { carbon |= KeyCombo.cmd; symbols += "⌘" }
        let keyCode = UInt32(event.keyCode)
        let key = Self.specialKeyNames[keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        self.init(keyCode: keyCode, carbonModifiers: carbon, display: symbols + key)
    }

    static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_DownArrow): "↓", UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}
