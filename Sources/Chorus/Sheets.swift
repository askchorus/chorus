import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox

/// What the comparison sheet shows, as an object the sheet observes itself. Built from the
/// parent's @State values instead, the sheet froze on its first presentation: macOS makes it
/// from a snapshot taken before the presenting transaction (not working, no text), and the
/// streamed changes after that never reached it — a blank sheet for the whole think, then the
/// finished answer in one go. Deferring the presentation a runloop stopped being enough. An
/// observed object is the same reference in any snapshot, and its changes arrive directly.
@MainActor
final class SummaryModel: ObservableObject {
    @Published var text = ""
    @Published var streaming = false
    /// The answers went to the model as [A], [B]… (see SummaryPrompt); this maps them back.
    @Published var names: SummaryPrompt.Names = [:]
    /// A reasoning model's thinking as it streams in — something to watch instead of a blank
    /// wait; folded away under the answer once that starts.
    @Published var thinking = ""
    /// Finished while its window was out of sight: the composer shows "ready".
    @Published var unseen = false
    /// The running comparison, so Stop and a new comparison can end it.
    var task: Task<Void, Never>? = nil
    /// Which comparison is current: gathering the answers takes a moment, and one that was
    /// stopped or overtaken by a newer one mustn't carry on when its answers come back.
    var run = UUID()

    var shown: String { SummaryPrompt.reveal(text, names: names) }
    var shownThinking: String { SummaryPrompt.reveal(thinking, names: names) }

    /// A fresh comparison: whatever was running stops, the old result goes.
    func reset() {
        task?.cancel(); task = nil; run = UUID()
        text = ""; thinking = ""; names = [:]; unseen = false; streaming = false
    }

    func stop() {
        task?.cancel(); task = nil
        streaming = false
    }
}

/// The "summarize all answers" result — streams in, then renders as markdown.
struct SummarySheet: View {
    @ObservedObject var model: SummaryModel
    let onClose: () -> Void
    var onStop: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var thinkingOpen = false

    var body: some View {
        let text = model.shown, streaming = model.streaming, thinking = model.shownThinking
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SparkleGlyph().fill(ChorusTheme.brandOrange).frame(width: 15, height: 15)
                Text(L("summary.title")).font(.chorus(16, .bold)).foregroundColor(ChorusTheme.brandOrange)
                if streaming {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer()
                if streaming, let onStop { Button(L("summary.stop"), action: onStop) }
                Button(L("common.close"), action: onClose)
            }
            .padding()
            PaneDivider(vertical: false)
            if streaming && text.isEmpty {
                // The model is thinking — with a reasoner model nothing streams for 10-30s (the
                // thinking isn't surfaced, only the final answer). A small top-left spinner still
                // read as a blank/stuck sheet, so make the working state CENTERED and unmissable.
                VStack(spacing: 14) {
                    Spacer()
                    InkLineup(thinking: true).frame(height: 104)
                    Text(L("summary.working"))
                        .font(.chorus(15, .semibold))
                    Text(L("summary.workingHint"))
                        .font(.chorus(12))
                        .foregroundColor(.secondary)
                    if !thinking.isEmpty {
                        ThinkingTail(text: thinking)
                            .frame(maxHeight: 150)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !thinking.isEmpty {
                            DisclosureGroup(isExpanded: $thinkingOpen) {
                                Text(thinking)
                                    .font(.system(size: 12)).lineSpacing(2).foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Text(L("summary.thinkingLabel")).font(.chorus(12, .semibold)).foregroundColor(.secondary)
                            }
                        }
                        Group {
                            if streaming {
                                Text(text).font(.system(size: 13)).lineSpacing(3)   // plain while streaming (fast)
                            } else {
                                MarkdownText(text: text)                            // pretty once done
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        // The main window's own surface instead of the stark default sheet white — half the
        // "blank screen" feel was the colour itself.
        .background(ChorusTheme.chrome(colorScheme))
    }
}


/// A reasoning model's thinking while it streams: its latest part, kept scrolled to the end.
private struct ThinkingTail: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(String(text.suffix(1500)))
                    .font(.system(size: 11.5)).lineSpacing(2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("end")
            }
            .onChange(of: text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// The win-rate list: one row per AI, best rate first.
struct StatsRows: View {
    let rows: [StatsSheet.Row]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(r.name).font(.chorus(13, .semibold))
                        if r.shown < 30 {
                            Text(L("stats.lowSample")).font(.chorus(10)).foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .inkChip()
                        }
                        Spacer()
                        Text("\(Int((r.rate * 100).rounded()))%").font(.chorus(13, .bold))
                        Text("· \(r.wins)/\(r.shown)").font(.chorus(11)).foregroundColor(.secondary)
                    }
                    // Ink bars, the leader's in trophy gold — the same verdict colour as the
                    // trophy that fills these numbers.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Ink.line(colorScheme).opacity(0.08)).frame(height: 8)
                            Capsule().fill(i == 0 ? Ink.gold : Ink.line(colorScheme).opacity(0.5))
                                .frame(width: max(4, geo.size.width * r.rate), height: 8)
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
    }
}

// MARK: - Share card

struct ShareAnswer { let name: String; let color: Color; let text: String }
struct ShareCardData { let question: String; let answers: [ShareAnswer] }

/// Desktop vs mobile share sizes. Mobile is narrow (reads better forwarded in WeChat/IM on a
/// phone); desktop is wider (better for Twitter / a monitor).
enum ShareCardWidth: CaseIterable {
    case desktop, mobile
    var px: CGFloat { self == .desktop ? 640 : 390 }
    var label: String { self == .desktop ? L("share.sizeDesktop") : L("share.sizeMobile") }
}

/// A warm, branded comparison card rendered to an image: the question on top, then each AI's
/// full answer (accent dot + name + text). Built off the same extraction that powers "summarize",
/// so it works for both web and API panels.
private struct ShareCardView: View {
    let question: String
    let answers: [ShareAnswer]
    var width: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !question.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Q").font(.chorus(15, .heavy))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ChorusTheme.brandOrange))
                    Text(question)
                        .font(.chorus(18, .semibold))
                        .foregroundColor(.black.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().opacity(0.4)
            }

            ForEach(answers.indices, id: \.self) { i in
                let a = answers[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Circle().fill(a.color).frame(width: 9, height: 9)
                        Text(a.name).font(.chorus(14, .bold))
                            .foregroundColor(.black.opacity(0.8))
                    }
                    Text(a.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 13))
                        .foregroundColor(.black.opacity(0.74))
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                InkLineup().frame(height: 20).environment(\.colorScheme, .light)   // the card is always light
                Text(L("share.brand")).font(.chorus(11, .semibold))
                Spacer()
            }
            .foregroundColor(.black.opacity(0.4))
            .padding(.top, 2)
        }
        .padding(28)
        .frame(width: width, alignment: .leading)
        .background(
            LinearGradient(colors: ChorusTheme.cardCream,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

/// Preview the rendered card with a desktop/mobile size toggle and copy / save actions. The image
/// is rendered here (not upstream) so switching size re-renders without re-scraping.
struct ShareCardSheet: View {
    let data: ShareCardData?
    let onClose: () -> Void
    @State private var size: ShareCardWidth = .desktop
    @State private var rendered: NSImage? = nil
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("share.title")).font(.headline)
                Spacer()
                Button(L("common.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            if data == nil {
                Spacer()
                Text(L("share.empty"))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary).padding(40)
                Spacer()
            } else {
                Picker("", selection: $size) {
                    ForEach(ShareCardWidth.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: 220).padding(.vertical, 10)

                ScrollView {
                    if let rendered {
                        Image(nsImage: rendered)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 18).padding(.bottom, 18)
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button {
                    if let rendered { copy(rendered); copied = true }
                } label: { Label(copied ? L("share.copied") : L("share.copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(rendered == nil)
                Button {
                    if let rendered { save(rendered) }
                } label: { Label(L("share.save"), systemImage: "square.and.arrow.down") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rendered == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 700, height: 760)
        .onAppear(perform: render)
        .onChange(of: size) { _ in copied = false; render() }
    }

    @MainActor private func render() {
        guard let data else { rendered = nil; return }
        MemoryHeartbeat.shared.note("share card render width=\(Int(size.px)) answers=\(data.answers.count)")
        let r = ImageRenderer(content: ShareCardView(question: data.question, answers: data.answers, width: size.px))
        r.scale = 2
        rendered = r.nsImage
    }

    private func copy(_ img: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    private func save(_ img: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "chorus-card.png"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url,
                  let tiff = img.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }
}

// MARK: - First-run welcome

/// A single, prominent welcome card shown once on first launch. One screen, big readable text,
/// three clear steps, warm theme — no per-panel repetition, no multi-step wizard.
struct WelcomeSheet: View {
    let onStart: () -> Void
    private let accent = ChorusTheme.brandOrange
    // Read the live quick-input binding so the card always shows the real shortcut, formatted the
    // same way Settings does (defaults match SettingsView: ⌘⇧C).
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode: Int = Int(kVK_ANSI_C)
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers: Int = Int(cmdKey | shiftKey)

    var body: some View {
        let hotkey = formatHotkey(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
        return VStack(spacing: 0) {
            VStack(spacing: 16) {
                InkLineup(hello: true)
                    .frame(height: 104)
                    .environment(\.colorScheme, .light)   // this sheet is always the light cream card
                VStack(spacing: 7) {
                    Text(L("welcome.title"))
                        .font(.chorus(27, .bold))
                        .foregroundColor(.black.opacity(0.85))
                    Text(L("welcome.subtitle"))
                        .font(.chorus(14.5))
                        .foregroundColor(.black.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 36)
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 22) {
                step("person.crop.circle.fill", L("welcome.step1.title"), L("welcome.step1.desc"))
                step("paperplane.fill", L("welcome.step2.title"), L("welcome.step2.desc"))
                step("bolt.fill", L("welcome.step3.title"), Lf("welcome.step3.desc", hotkey))
            }
            .padding(.horizontal, 40)

            Spacer(minLength: 16)

            // The #1 first-launch anxiety is "why am I signing in to three sites inside an
            // unfamiliar app?" — answer it before asking anything of the user.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black.opacity(0.4))
                    .padding(.top, 1)
                Text(L("welcome.privacy"))
                    .font(.chorus(11.5))
                    .foregroundColor(.black.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 42)

            Spacer(minLength: 16)

            // The film's (and the landing page's) button: orange, inked outline, hard shadow.
            Button(action: onStart) {
                Text(L("welcome.start"))
                    .font(.chorus(15.5, .bold))
                    .foregroundColor(Ink.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(accent))
                    .overlay(Capsule().strokeBorder(Ink.ink, lineWidth: 2))
                    .background(Capsule().fill(Ink.ink).offset(y: 4))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 40)
            .padding(.bottom, 34)
        }
        .frame(width: 470, height: 560)
        .background(
            LinearGradient(colors: ChorusTheme.cardCream,
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func step(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundColor(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.chorus(16, .semibold)).foregroundColor(.black.opacity(0.82))
                Text(desc).font(.chorus(13.5)).foregroundColor(.black.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Win-rate stats

/// "Which AI do I like most" dashboard. Computes WIN RATE (wins ÷ rounds where the panel was a
/// contender) live from votes.jsonl — never raw win counts (which favor whoever appears most).
/// Sample-size gated: a leaderboard that screams a winner at n=5 is the real failure mode.
struct StatsSheet: View {
    let onClose: () -> Void
    @State private var range: StatRange = .all
    @Environment(\.colorScheme) private var colorScheme

    enum StatRange: CaseIterable {
        case week, month, all
        var label: String { self == .week ? L("stats.range7") : self == .month ? L("stats.range30") : L("stats.rangeAll") }
        var days: Int? { self == .week ? 7 : self == .month ? 30 : nil }
    }

    struct Row: Identifiable {
        let id: String, name: String
        let wins: Int, shown: Int
        var rate: Double { shown == 0 ? 0 : Double(wins) / Double(shown) }
    }

    private func rows() -> [Row] {
        let votes = VoteStore.shared.votesForStats()
        let cutoff = range.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        let iso = ISO8601DateFormatter()
        var wins: [String: Int] = [:], shown: [String: Int] = [:], names: [String: String] = [:]
        for v in votes {
            if let c = cutoff, let t = iso.date(from: v.ts), t < c { continue }
            guard let w = v.winner else { continue }
            for k in v.contenders { shown[k, default: 0] += 1; if let n = v.names[k] { names[k] = n } }
            wins[w, default: 0] += 1
        }
        // Each AI under the name it has NOW: a vote keeps the name from its day, so a panel renamed
        // since (or an API panel saved as "deepseek") would otherwise show its old spelling.
        let current = Dictionary(ProviderRegistry.all().map { ($0.key, $0.name) }
                                 + APIProviderRegistry.all().map { ($0.id, $0.name) },
                                 uniquingKeysWith: { first, _ in first })
        return shown.keys.map { Row(id: $0, name: current[$0] ?? names[$0] ?? $0, wins: wins[$0] ?? 0, shown: shown[$0] ?? 0) }
            .sorted { ($0.rate, $0.shown) > ($1.rate, $1.shown) }
    }

    var body: some View {
        let data = rows()
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TrophyGlyph(won: true).frame(width: 16, height: 15)
                Text(L("stats.title")).font(.chorus(16, .bold))
                Spacer()
                Button(L("common.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            PaneDivider(vertical: false)

            Picker("", selection: $range) {
                ForEach(StatRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(.vertical, 10)

            if data.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    InkLineup().frame(height: 84)
                    Text(L("stats.empty"))
                        .font(.chorus(13)).multilineTextAlignment(.center).foregroundColor(.secondary)
                }
                .padding(40)
                Spacer()
            } else {
                ScrollView {
                    StatsRows(rows: data).padding(18)
                }
                PaneDivider(vertical: false)
                Text(L("stats.disclaimer"))
                    .font(.chorus(11)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 560)
        .background(ChorusTheme.chrome(colorScheme))
    }
}
