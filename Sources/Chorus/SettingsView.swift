import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode: Int = Int(kVK_ANSI_C)
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers: Int = Int(cmdKey | shiftKey)
    @AppStorage("foregroundMainOnSend") private var foregroundMainOnSend: Bool = true
    @AppStorage("autoPasteOnSummon") private var autoPasteOnSummon: Bool = true
    @AppStorage("notifyMode") private var notifyMode: String = "quickOnly"
    @AppStorage("notifyWaitAllVisible") private var notifyWaitAllVisible: Bool = true
    @AppStorage("notifyRequiredProviders") private var notifyRequiredProvidersRaw: String = "chatgpt,claude,gemini"
    @AppStorage("customTextChips") private var textChipsRaw: String = kDefaultChipPrompts.joined(separator: "\n")
    @AppStorage("customImageChips") private var imageChipsRaw: String = kImageChipPrompts.joined(separator: "\n")
    @AppStorage("customProviders") private var customProvidersRaw: String = ""
    @AppStorage("restoreSession") private var restoreSession: Bool = true
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @AppStorage("appearance") private var appearance: String = "light"
    @AppStorage("warmWebPages") private var warmWebPages: Bool = true
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("minimalMode") private var minimalMode: Bool = false
    @State private var wechatCopied = false
    @State private var wechatCopyGen = 0   // invalidates stale ✓-reset timers on rapid re-clicks

    /// A settings description caption — hidden in Minimal mode.
    @ViewBuilder private func hint(_ key: String) -> some View {
        if !minimalMode {
            Text(L(key))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 3)
        }
    }

    @State private var newProviderName: String = ""
    @State private var newProviderURL: String = ""

    // API model (OpenAI-compatible) add form.
    @AppStorage("apiProviders") private var apiProvidersRaw: String = ""
    @State private var newAPIName: String = ""
    @State private var newAPIBase: String = ""
    @State private var newAPIModel: String = ""
    @State private var newAPIKey: String = ""
    @State private var editingAPIId: String? = nil   // non-nil → the add form is editing this provider

    // Decode from the observed @AppStorage (not APIProviderRegistry.all()) so the list updates
    // live when a provider is added/removed — reading apiProvidersRaw establishes the dependency.
    private var apiProviders: [APIProvider] { APIProviderRegistry.decode(apiProvidersRaw) }

    /// Built-ins + user-added providers. Recomputes when customProvidersRaw changes.
    private var allProviders: [Provider] {
        ProviderRegistry.builtIn + ProviderRegistry.decode(customProvidersRaw)
    }

    private func addProvider() {
        if ProviderRegistry.addCustom(name: newProviderName, urlString: newProviderURL) {
            newProviderName = ""
            newProviderURL = ""
        }
    }

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
            Section(L("settings.section.language")) {
                Picker(L("settings.language.label"), selection: $appLanguage) {
                    Text(L("settings.language.system")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
            }

            Section(L("settings.section.appearance")) {
                Picker(L("settings.appearance.label"), selection: $appearance) {
                    Text(L("settings.appearance.system")).tag("system")
                    Text(L("settings.appearance.light")).tag("light")
                    Text(L("settings.appearance.dark")).tag("dark")
                }
                .pickerStyle(.segmented)

                hint("settings.appearance.desc")

                Toggle(L("settings.warmWeb"), isOn: $warmWebPages)
                    .padding(.vertical, 2)
                    .onChange(of: warmWebPages) { on in
                        WebViewStore.shared.setWarmTint(on)
                    }
                hint("settings.warmWeb.desc")

                Toggle(L("settings.minimalMode"), isOn: $minimalMode)
                    .padding(.vertical, 2)
                hint("settings.minimalMode.desc")
            }

            Section(L("settings.section.menubar")) {
                Toggle(L("settings.menubar.show"), isOn: $showMenuBarIcon)
                    .padding(.vertical, 2)
                hint("settings.menubar.desc")
            }

            Section(L("settings.section.quickInput")) {
                HotkeyRecorder(
                    keyCode: $hotkeyKeyCode,
                    modifiers: $hotkeyModifiers
                ) { kc, mods in
                    HotkeyManager.shared.register(
                        keyCode: UInt32(kc),
                        modifiers: UInt32(mods)
                    )
                }

                Toggle(L("settings.foregroundOnSend"), isOn: $foregroundMainOnSend)
                    .padding(.vertical, 2)

                Toggle(L("settings.autoPaste"), isOn: $autoPasteOnSummon)
                    .padding(.vertical, 2)

                hint("settings.quickInput.desc")
            }

            Section(L("settings.section.providers")) {
                Toggle(L("settings.restoreSession"), isOn: $restoreSession)
                    .padding(.vertical, 2)
                hint("settings.restoreSession.desc")

                hint("settings.providers.desc")

                ForEach(allProviders) { p in
                    HStack(spacing: 8) {
                        Text(p.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(p.url.host ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if p.isBuiltIn {
                            Text(L("settings.providers.builtin"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Button {
                                WebViewStore.shared.removeWebView(key: p.key)
                                ProviderRegistry.removeCustom(key: p.key)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(Lf("settings.providers.remove", p.name))
                        }
                    }
                    .padding(.vertical, 2)
                }

                // One-click presets for popular real AIs not already added.
                let addedHosts = Set(allProviders.compactMap { $0.url.host })
                let availablePresets = ProviderRegistry.presets.filter { preset in
                    guard let h = URL(string: preset.url)?.host else { return false }
                    return !addedHosts.contains { $0.contains(h) || h.contains($0) }
                }
                if !availablePresets.isEmpty {
                    Text(L("settings.providers.quickAdd"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    FlowLayout(spacing: 8) {
                        ForEach(availablePresets, id: \.url) { preset in
                            Button {
                                ProviderRegistry.addCustom(name: preset.name, urlString: preset.url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                    Text(preset.name).font(.system(size: 12))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help(preset.url)
                        }
                    }
                }

                // Or add any other AI by name + URL.
                HStack(spacing: 8) {
                    TextField(text: $newProviderName, prompt: Text(L("settings.providers.name"))) { EmptyView() }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField(text: $newProviderURL, prompt: Text("https://chat.deepseek.com")) { EmptyView() }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addProvider)
                    Button(L("settings.providers.add"), action: addProvider)
                        .disabled(newProviderURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4)
            }

            Section(L("settings.section.apiModels")) {
                hint("settings.api.desc")

                ForEach(apiProviders) { p in
                    HStack(spacing: 8) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(p.model.isEmpty ? (p.baseURL) : p.model)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Spacer()
                        Button {
                            editingAPIId = p.id
                            newAPIName = p.name
                            newAPIBase = p.baseURL
                            newAPIModel = p.model
                            newAPIKey = ""   // blank = keep the existing key
                        } label: { Image(systemName: "pencil").foregroundColor(.secondary) }
                            .buttonStyle(.plain)
                            .help(Lf("settings.api.edit", p.name))
                        Button {
                            APIProviderRegistry.remove(id: p.id)
                            if editingAPIId == p.id { editingAPIId = nil; newAPIName = ""; newAPIBase = ""; newAPIModel = ""; newAPIKey = "" }
                            apiProvidersRaw = UserDefaults.standard.string(forKey: "apiProviders") ?? ""
                        } label: { Image(systemName: "trash").foregroundColor(.secondary) }
                            .buttonStyle(.plain)
                            .help(Lf("settings.api.remove", p.name))
                    }
                    .padding(.vertical, 2)
                }

                // One-tap presets prefill the form below.
                Text(L("settings.api.presets")).font(.caption).foregroundColor(.secondary).padding(.top, 4)
                FlowLayout(spacing: 8) {
                    ForEach(APIProviderRegistry.presets, id: \.name) { preset in
                        Button {
                            newAPIName = preset.name
                            newAPIBase = preset.baseURL
                            newAPIModel = preset.model
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                Text(preset.name).font(.system(size: 12))
                                if !preset.needsKey {
                                    Text(L("settings.api.local")).font(.system(size: 9)).foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .help(preset.baseURL)
                    }
                }

                // Add form
                HStack(spacing: 8) {
                    TextField(text: $newAPIName, prompt: Text(L("settings.api.name"))) { EmptyView() }
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 110)
                    TextField(text: $newAPIModel, prompt: Text(L("settings.api.model"))) { EmptyView() }
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 150)
                }
                .padding(.top, 2)
                TextField(text: $newAPIBase, prompt: Text("https://api.openai.com/v1")) { EmptyView() }
                    .labelsHidden().textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    SecureField(text: $newAPIKey,
                                prompt: Text(editingAPIId == nil ? L("settings.api.key") : L("settings.api.keyEdit"))) { EmptyView() }
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    if editingAPIId != nil {
                        Button(L("settings.api.cancel")) {
                            editingAPIId = nil
                            newAPIName = ""; newAPIBase = ""; newAPIModel = ""; newAPIKey = ""
                        }
                    }
                    Button(editingAPIId == nil ? L("settings.api.add") : L("settings.api.save")) {
                        let ok: Bool
                        if let id = editingAPIId {
                            ok = APIProviderRegistry.update(id: id, name: newAPIName, baseURL: newAPIBase, model: newAPIModel, apiKey: newAPIKey)
                        } else {
                            ok = APIProviderRegistry.add(name: newAPIName, baseURL: newAPIBase, model: newAPIModel, apiKey: newAPIKey)
                        }
                        if ok {
                            newAPIName = ""; newAPIBase = ""; newAPIModel = ""; newAPIKey = ""
                            editingAPIId = nil
                            apiProvidersRaw = UserDefaults.standard.string(forKey: "apiProviders") ?? ""
                        }
                    }
                    .disabled(newAPIName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newAPIBase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section(L("settings.section.notifications")) {
                Picker(L("settings.notify.picker"), selection: $notifyMode) {
                    Text(L("settings.notify.off")).tag("off")
                    Text(L("settings.notify.quickOnly")).tag("quickOnly")
                    Text(L("settings.notify.always")).tag("always")
                }
                .pickerStyle(.menu)

                hint("settings.notify.desc")

                HStack {
                    Button(L("settings.notify.test")) {
                        CompletionNotifier.shared.sendTestNotification()
                    }
                    if !minimalMode {
                        Text(L("settings.notify.testDesc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)

                Divider().padding(.vertical, 4)

                Toggle(L("settings.notify.waitAllVisible"), isOn: $notifyWaitAllVisible)
                hint("settings.notify.waitAllVisible.desc")

                if !notifyWaitAllVisible {
                    Text(L("settings.notify.waitFor"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    ForEach(allProviders) { p in
                        Toggle(p.name, isOn: requiredBinding(for: p.key))
                            .padding(.leading, 4)
                    }
                    // Native API panels can block the notification too.
                    ForEach(apiProviders) { p in
                        Toggle("\(p.name)  ·  API", isOn: requiredBinding(for: p.id))
                            .padding(.leading, 4)
                    }

                    hint("settings.notify.waitDesc")
                }
            }

            Section(L("settings.section.quickPrompts")) {
                hint("settings.prompts.desc")

                ChipListEditor(title: L("settings.prompts.textChips"),
                               raw: $textChipsRaw,
                               defaults: kDefaultChipPrompts)

                ChipListEditor(title: L("settings.prompts.imageChips"),
                               raw: $imageChipsRaw,
                               defaults: kImageChipPrompts)
            }

            Section(L("settings.section.about")) {
                hint("settings.about.hint")
                HStack {
                    Text(L("settings.about.contact"))
                    Spacer()
                    Link("smileduck@duck.com",
                         destination: URL(string: "mailto:smileduck@duck.com?subject=Chorus%20%E5%8F%8D%E9%A6%88")!)
                }
                HStack {
                    Text(L("settings.about.wechat"))
                    Spacer()
                    Text("346436018")
                        .textSelection(.enabled)
                        .foregroundColor(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("346436018", forType: .string)
                        wechatCopied = true
                        wechatCopyGen += 1
                        let gen = wechatCopyGen
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if wechatCopyGen == gen { wechatCopied = false }
                        }
                    } label: {
                        Image(systemName: wechatCopied ? "checkmark" : "doc.on.doc")
                            .foregroundColor(wechatCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(wechatCopied ? L("settings.about.copied") : L("settings.about.copyWechat"))
                }
                HStack {
                    Text(L("settings.about.version"))
                    Spacer()
                    Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Light-touch theming: hide the Form's default (cold grey) scroll background and put the
        // warm canvas behind it, so Settings reads as the same product as the main window. The
        // grouped section cards stay system-drawn (recoloring those fights SwiftUI and risks a
        // half-native look). Scheme-aware: cream in light, dark in dark.
        .scrollContentBackground(.hidden)
        .background(ChorusTheme.canvas(colorScheme).ignoresSafeArea())
        .frame(width: 520, height: 600)
        .onChange(of: appearance) { newValue in
            AppearanceManager.apply(newValue)
        }
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
                    Label(L("settings.prompts.restore"), systemImage: "arrow.uturn.backward")
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
                TextField(text: $newChip, prompt: Text(L("settings.prompts.addPlaceholder"))) {
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
            Text(L("settings.hotkey.label"))
            Spacer()

            Button {
                toggleRecording()
            } label: {
                Text(isRecording ? L("settings.hotkey.recording") : formatHotkey(keyCode: keyCode, modifiers: modifiers))
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
            .help(L("settings.hotkey.reset"))
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
