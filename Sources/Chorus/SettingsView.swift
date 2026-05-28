import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode: Int = Int(kVK_ANSI_C)
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers: Int = Int(cmdKey | shiftKey)
    @AppStorage("foregroundMainOnSend") private var foregroundMainOnSend: Bool = true
    @AppStorage("autoPasteOnSummon") private var autoPasteOnSummon: Bool = true
    @AppStorage("notifyMode") private var notifyMode: String = "quickOnly"
    @AppStorage("notifyRequiredProviders") private var notifyRequiredProvidersRaw: String = "chatgpt,claude,gemini"
    @AppStorage("customTextChips") private var textChipsRaw: String = kDefaultChipPrompts.joined(separator: "\n")
    @AppStorage("customImageChips") private var imageChipsRaw: String = kImageChipPrompts.joined(separator: "\n")

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

                Toggle("Auto-paste clipboard when summoning", isOn: $autoPasteOnSummon)
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

            Section("Quick Prompts") {
                Text("Tapping a chip in the quick input instantly broadcasts with that text as a prefix. One chip per line.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)

                ChipListEditor(title: "Text-mode chips",
                               raw: $textChipsRaw,
                               defaults: kDefaultChipPrompts)

                ChipListEditor(title: "Image-mode chips (shown when an image is attached)",
                               raw: $imageChipsRaw,
                               defaults: kImageChipPrompts)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
    }

}

// MARK: - Quick-prompt chip editor (pill UI)

/// Editable list of quick-prompt chips, shown as removable capsule pills (matching how they
/// look in the quick input) plus an inline add field. Backed by a newline-joined @AppStorage
/// string so it stays in sync with what the quick input reads.
struct ChipListEditor: View {
    let title: String
    @Binding var raw: String
    let defaults: [String]

    @State private var newChip: String = ""
    @FocusState private var addFocused: Bool

    private var chips: [String] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commit(_ list: [String]) { raw = list.joined(separator: "\n") }

    private func addChip() {
        let t = newChip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = chips
        if !list.contains(t) { list.append(t) }
        commit(list)
        newChip = ""
        addFocused = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    commit(defaults)
                } label: {
                    Label("Restore defaults", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if !chips.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { idx, chip in
                        ChipPill(text: chip) {
                            var list = chips
                            if idx < list.count { list.remove(at: idx) }
                            commit(list)
                        }
                    }
                }
            }

            // Native rounded-border field: correct caret position + reliable click-to-focus
            // (a plain TextField stretched inside a custom HStack mis-placed the caret and
            // swallowed taps, so focus wouldn't move between the two editors).
            HStack(spacing: 8) {
                // On macOS the first TextField arg is a LEFT-SIDE LABEL (not an in-field
                // placeholder as on iOS) — that's what pushed "Add a prompt…" to the left and
                // the caret to the right. Use an empty label + `prompt:` for a real in-field
                // placeholder, and labelsHidden() so the field spans full width.
                TextField(text: $newChip, prompt: Text("Add a prompt…")) {
                    EmptyView()
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($addFocused)
                .onSubmit(addChip)
                Button(action: addChip) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(
                            newChip.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.secondary.opacity(0.4)
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(newChip.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add prompt")
            }
        }
        .padding(.vertical, 4)
    }
}

/// A single chip rendered as a capsule with a delete (×) button — visually matches the
/// chips shown in the quick input.
struct ChipPill: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Minimal flow layout: lays subviews left-to-right, wrapping to a new line when the next
/// one would exceed the available width. (macOS 13+ Layout protocol.)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        let totalWidth = (maxWidth == .infinity) ? widest : maxWidth
        return CGSize(width: max(0, totalWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
