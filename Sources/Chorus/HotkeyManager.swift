import Foundation
import Carbon.HIToolbox
import AppKit

/// Global hotkey via Carbon's RegisterEventHotKey. Single instance; one hotkey at a time.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    private(set) var currentKeyCode: UInt32 = 0
    private(set) var currentModifiers: UInt32 = 0

    /// Called (on main thread) when the registered hotkey is pressed.
    var onTrigger: (() -> Void)?

    private init() {}

    /// Re-register the hotkey. Old binding (if any) is replaced.
    /// - keyCode: Carbon virtual key code (e.g. kVK_ANSI_C)
    /// - modifiers: Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey)
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x43484F52), id: 1) // 'CHOR'
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            currentKeyCode = keyCode
            currentModifiers = modifiers
            return true
        } else {
            print("RegisterEventHotKey failed: \(status)")
            return false
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )
    }
}

/// Convert a Carbon virtual key code into a display string (for showing hotkey config in UI).
func keyCodeToDisplayString(_ kc: Int) -> String {
    // Cover the common keys; fallback to "Key<N>" for exotic ones.
    let map: [Int: String] = [
        // Letters
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        // Numbers
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        // Special
        49: "Space", 36: "↵", 48: "⇥", 53: "esc", 51: "⌫",
        123: "←", 124: "→", 126: "↑", 125: "↓",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        // Symbols
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
        42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
    ]
    return map[kc] ?? "Key\(kc)"
}

/// Format a hotkey (carbon keyCode + modifiers) as "⌃⌥⇧⌘X"
func formatHotkey(keyCode: Int, modifiers: Int) -> String {
    var s = ""
    if modifiers & Int(controlKey) != 0 { s += "⌃" }
    if modifiers & Int(optionKey) != 0 { s += "⌥" }
    if modifiers & Int(shiftKey) != 0 { s += "⇧" }
    if modifiers & Int(cmdKey) != 0 { s += "⌘" }
    s += keyCodeToDisplayString(keyCode)
    return s
}
