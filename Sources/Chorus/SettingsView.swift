import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode: Int = Int(kVK_ANSI_C)
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers: Int = Int(cmdKey | shiftKey)
    @AppStorage("foregroundMainOnSend") private var foregroundMainOnSend: Bool = true
    @AppStorage("notifyMode") private var notifyMode: String = "quickOnly"
    @AppStorage("notifyRequiredProviders") private var notifyRequiredProvidersRaw: String = "chatgpt,claude,gemini"

    private func requiredBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                Set(notifyRequiredProvidersRaw.split(separator: ",").map(String.init)).contains(key)
            },
            set: { newValue in
                var set = Set(notifyRequiredProvidersRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
                if newValue { set.insert(key) } else { set.remove(key) }
                notifyRequiredProvidersRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    var body: some View {
        Form {
            Section("Quick Input") {
                HotkeyRecorder(
                    keyCode: $hotkeyKeyCode,
                    modifiers: $hotkeyModifiers
                ) { kc, mods in
                    HotkeyManager.shared.register(
                        keyCode: UInt32(kc),
                        modifiers: UInt32(mods)
                    )
                }

                Toggle("Bring Chorus to front after sending", isOn: $foregroundMainOnSend)
                    .padding(.vertical, 2)

                Text("Press the shortcut anywhere to summon a floating input. Type, hit Return to broadcast to all visible AIs. Cmd+V pastes an image.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }

            Section("Notifications") {
                Picker("Alert when all AIs finish", selection: $notifyMode) {
                    Text("Off").tag("off")
                    Text("Only from quick input").tag("quickOnly")
                    Text("Always").tag("always")
                }
                .pickerStyle(.menu)

                Text("Plays the system notification sound and shows a banner when all visible AIs have finished streaming. Skipped if the Chorus window is already in front.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)

                HStack {
                    Button("Send test notification") {
                        CompletionNotifier.shared.sendTestNotification()
                    }
                    Text("Click to verify permission/delivery is working.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                Divider().padding(.vertical, 4)

                Text("Wait for these AIs before notifying")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ForEach(allProviders) { p in
                    Toggle(p.name, isOn: requiredBinding(for: p.key))
                        .padding(.leading, 4)
                }

                Text("Uncheck slow/flaky AIs (e.g. Gemini) so they don't block the alert. The broadcast still goes to them; their reply just arrives whenever it finishes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
    }
}

/// A hotkey recorder field. Click to enter recording mode, then press a key combo.
/// Requires at least one modifier (Cmd/Shift/Option/Control) to avoid binding bare keys.
struct HotkeyRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var onChange: (Int, Int) -> Void

    @State private var isRecording = false
    @State private var keyMonitor: Any? = nil

    var body: some View {
        HStack {
            Text("Quick input shortcut")
            Spacer()

            Button {
                toggleRecording()
            } label: {
                Text(isRecording ? "Press combo..." : formatHotkey(keyCode: keyCode, modifiers: modifiers))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 160, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.3))
                    )
            }
            .buttonStyle(.plain)

            Button {
                resetToDefault()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reset to ⌘⇧C")
            .disabled(isRecording)
        }
        .padding(.vertical, 2)
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels recording
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let nsMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasMod = nsMods.contains(.command) || nsMods.contains(.shift)
                      || nsMods.contains(.option) || nsMods.contains(.control)
            // Require at least one modifier; pure-key triggers would be too easy to fire by accident
            guard hasMod else { return event }

            var carbonMods: Int = 0
            if nsMods.contains(.command) { carbonMods |= Int(cmdKey) }
            if nsMods.contains(.shift)   { carbonMods |= Int(shiftKey) }
            if nsMods.contains(.option)  { carbonMods |= Int(optionKey) }
            if nsMods.contains(.control) { carbonMods |= Int(controlKey) }

            keyCode = Int(event.keyCode)
            modifiers = carbonMods
            onChange(keyCode, modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        isRecording = false
    }

    private func resetToDefault() {
        keyCode = Int(kVK_ANSI_C)
        modifiers = Int(cmdKey | shiftKey)
        onChange(keyCode, modifiers)
    }
}
