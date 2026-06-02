import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The body of an API model's card: its conversation (rendered natively) plus a small input so
/// you can talk to JUST this model, in addition to the unified broadcast. The card chrome
/// (accent bar + slim header) is added by ContentView.
struct APIPanelView: View {
    let provider: APIProvider
    @ObservedObject private var store = APIChatStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var input = ""
    @State private var attachedImage: NSImage? = nil       // ⌘V-pasted image for this panel (vision)
    @StateObject private var dictator = SpeechDictator()   // per-panel voice input
    @State private var dictationBase = ""

    var body: some View {
        VStack(spacing: 0) {
            transcript
            inputBar
        }
    }

    private var transcript: some View {
        let msgs = store.messages(for: provider.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if msgs.isEmpty {
                        emptyState
                    } else {
                        ForEach(msgs) { MessageRow(message: $0) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(surface)
            // Follow the streaming reply to the bottom; also snap on a new turn.
            .onChange(of: msgs.last?.text) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: msgs.count) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Per-panel input — sends to THIS model only (the conversation keeps its own context).
    /// Supports ⌘V image paste (vision) and voice input; a shared coordinator stops any other mic.
    private var inputBar: some View {
        VStack(spacing: 6) {
            if let img = attachedImage {
                HStack(spacing: 6) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 34, height: 34)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Button { attachedImage = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                PasteAwareTextField(text: $input,
                                    placeholder: L("api.panel.ask"),
                                    onSubmit: send,
                                    onPasteImage: { attachedImage = $0 })
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                Button(action: toggleMic) {
                    Image(systemName: dictator.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 14))
                        .foregroundColor(dictator.isRecording ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(dictator.permissionDenied ? L("quick.micDenied")
                      : (dictator.isRecording ? L("quick.micStop") : L("quick.mic")))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(canSend
                            ? ProviderStyle.accent(key: provider.id, host: "")
                            : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        // Floating rounded input — mirrors the web panels' own composers (rounded box + margin)
        // instead of a flat edge-to-edge bar, so the native API card feels like the others.
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(inputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onChange(of: dictator.isRecording) { rec in
            if !rec { DictationCoordinator.shared.ended(dictator) }   // auto-stop / manual stop
        }
    }

    /// Input box fill — almost the SAME cream as the panel surface (#F1E9D9), just a hair lighter
    /// so the rounded composer is defined by its border, not by reading as a white tile (like the
    /// web panels' tinted composers, which sit at their page tone). Scheme-aware.
    private var inputFill: Color {
        colorScheme == .dark
            ? Color(red: 0.18, green: 0.18, blue: 0.20)
            : Color(red: 0.957, green: 0.929, blue: 0.873)   // ~#F4EDDF, barely above the surface
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImage != nil
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || attachedImage != nil else { return }
        dictator.stop()
        store.send(to: provider, prompt: t, imageBase64: attachedImage.flatMap(Self.pngBase64))
        input = ""
        attachedImage = nil
    }

    /// NSImage → base64 PNG, for the vision content payload.
    static func pngBase64(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }

    private func toggleMic() {
        if dictator.isRecording {
            dictator.stop()
            DictationCoordinator.shared.ended(dictator)
        } else {
            DictationCoordinator.shared.begin(dictator)   // stops any other active mic first
            dictationBase = input.isEmpty ? "" : input + " "
            dictator.start { text in input = dictationBase + text }
        }
    }

    /// Warm reading surface. Matched to what the WEB panels become after the warm-tint overlay
    /// (white × #f1e9d9 ≈ #f1e9d9), so the native API card sits at the same cream tone as the web
    /// cards instead of reading whiter. Dark surface in dark mode.
    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 0.135, green: 0.135, blue: 0.150)
            : Color(red: 0.945, green: 0.914, blue: 0.851)   // #F1E9D9 — same as tinted web pages
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(provider.model.isEmpty ? provider.name : provider.model)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(L("api.panel.waiting"))
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }
}

/// One message: the user's prompt as a right-aligned chip, the assistant's reply as flowing text
/// (plain while streaming — cheap to update token-by-token — then pretty markdown once finished).
private struct MessageRow: View {
    let message: ChatMessage

    static func decode(_ b64: String) -> NSImage? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 36)
                VStack(alignment: .trailing, spacing: 6) {
                    if let img = message.imageBase64.flatMap(Self.decode) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
                    }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty && message.isStreaming {
                    ThinkingDots()
                } else if message.isStreaming {
                    Text(message.text)                 // plain text while streaming (fast)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownText(text: message.text)   // pretty markdown once the reply is done
                }
                if let err = message.error {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Pragmatic markdown: split on ``` fences → code blocks render in a monospaced grey box; the
/// rest renders inline markdown (bold / italic / links / `code`) via AttributedString. Block
/// markers (lists, headings) show as-is — good enough for LLM output without a full parser.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if seg.isCode {
                    Text(seg.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.055)))
                } else {
                    Text(Self.inline(seg.text))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var segments: [(isCode: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var inCode = false
        var buf: [String] = []
        func flush() {
            let joined = buf.joined(separator: "\n")
            let t = inCode ? joined : joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append((inCode, t)) }
            buf.removeAll()
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush(); inCode.toggle()
            } else {
                buf.append(line)
            }
        }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

/// An NSTextField wrapper that intercepts ⌘V: if the clipboard holds an image it fires
/// `onPasteImage` (and pastes nothing as text); otherwise paste proceeds normally. A plain
/// SwiftUI TextField swallows ⌘V in its field editor before any SwiftUI paste hook runs, so
/// image paste needs this. Scoped to the field being edited (`currentEditor`), so with several
/// API panels open only the focused one's field reacts.
struct PasteAwareTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onPasteImage: (NSImage) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = PasteInterceptTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13)
        tf.placeholderString = placeholder
        tf.delegate = context.coordinator
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.onPasteImage = onPasteImage
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        tf.placeholderString = placeholder
        (tf as? PasteInterceptTextField)?.onPasteImage = onPasteImage
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PasteAwareTextField
        init(_ p: PasteAwareTextField) { parent = p }
        func controlTextDidChange(_ note: Notification) {
            if let tf = note.object as? NSTextField { parent.text = tf.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}

private final class PasteInterceptTextField: NSTextField {
    var onPasteImage: ((NSImage) -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V while THIS field is being edited + the clipboard has an image → attach, don't paste.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           currentEditor() != nil,
           let img = NSImage(pasteboard: .general), img.size.width > 0 {
            onPasteImage?(img)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Three softly pulsing dots, shown before the first token arrives.
private struct ThinkingDots: View {
    @State private var animate = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18), value: animate)
            }
        }
        .onAppear { animate = true }
        .padding(.vertical, 4)
    }
}
