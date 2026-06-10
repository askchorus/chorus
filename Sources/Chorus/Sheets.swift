import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox

/// The "summarize all answers" result — streams in, then renders as markdown.
struct SummarySheet: View {
    let text: String
    let streaming: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(.secondary)
                Text("各家回答汇总").font(.headline)
                if streaming {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer()
                Button("关闭", action: onClose)
            }
            .padding()
            Divider()
            ScrollView {
                Group {
                    if streaming {
                        Text(text).font(.system(size: 13)).lineSpacing(3)   // plain while streaming (fast)
                    } else {
                        MarkdownText(text: text)                            // pretty once done
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(width: 620, height: 560)
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
    var label: String { self == .desktop ? "电脑版" : "手机版" }
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
                    Text("Q").font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ChorusTheme.brandOrange))
                    Text(question)
                        .font(.system(size: 18, weight: .semibold))
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
                        Text(a.name).font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black.opacity(0.8))
                    }
                    Text(a.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 13))
                        .foregroundColor(.black.opacity(0.74))
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text("Chorus · 同时问多个 AI").font(.system(size: 11, weight: .medium))
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
                Text("分享卡片").font(.headline)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            if data == nil {
                Spacer()
                Text("没有可分享的内容\n先广播一个问题，等各家答完再来")
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
                } label: { Label(copied ? "已复制" : "复制图片", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(rendered == nil)
                Button {
                    if let rendered { save(rendered) }
                } label: { Label("保存…", systemImage: "square.and.arrow.down") }
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
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
                }
                VStack(spacing: 7) {
                    Text(L("welcome.title"))
                        .font(.system(size: 27, weight: .bold))
                        .foregroundColor(.black.opacity(0.85))
                    Text(L("welcome.subtitle"))
                        .font(.system(size: 14.5))
                        .foregroundColor(.black.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 44)
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 22) {
                step("person.crop.circle.fill", L("welcome.step1.title"), L("welcome.step1.desc"))
                step("paperplane.fill", L("welcome.step2.title"), L("welcome.step2.desc"))
                step("bolt.fill", L("welcome.step3.title"), Lf("welcome.step3.desc", hotkey))
            }
            .padding(.horizontal, 40)

            Spacer(minLength: 28)

            Button(action: onStart) {
                Text(L("welcome.start"))
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
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
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.black.opacity(0.82))
                Text(desc).font(.system(size: 13.5)).foregroundColor(.black.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
