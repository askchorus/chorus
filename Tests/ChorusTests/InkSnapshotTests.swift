import XCTest
import SwiftUI
@testable import Chorus

/// Renders the drawn UI pieces to PNGs for a look by eye — nothing is asserted about pixels.
/// Off by default; run with a directory to write into:
///   CHORUS_SNAPSHOTS=/tmp/chorus-snaps swift test --filter InkSnapshotTests
@MainActor
final class InkSnapshotTests: XCTestCase {
    private var outDir: URL!

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CHORUS_SNAPSHOTS"] else {
            throw XCTSkip("set CHORUS_SNAPSHOTS=<dir> to render snapshots")
        }
        outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        await MainActor.run { ChorusFont.register(from: repo.appendingPathComponent("scripts/fonts")) }
    }

    private func save<V: View>(_ name: String, _ view: V, scheme: ColorScheme = .light) throws {
        let bg: Color = scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.95, green: 0.93, blue: 0.89)
        let r = ImageRenderer(content: view.padding(16).background(bg).environment(\.colorScheme, scheme))
        r.scale = 2
        guard let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("render \(name)") }
        try png.write(to: outDir.appendingPathComponent(name + ".png"))
    }

    func testCharacters() throws {
        for scheme in [ColorScheme.light, .dark] {
            let poses: [(String, InkPose)] = [
                ("idle", InkPose()), ("singing", InkPose(mouth: 0.8, hop: 5)), ("happy", InkPose(happy: true)),
                ("down", InkPose(lookX: -0.35, lookY: 0.9)), ("blink", InkPose(eye: 0.2)),
            ]
            let big = VStack(alignment: .leading, spacing: 10) {
                ForEach(poses, id: \.0) { name, pose in
                    HStack(spacing: 14) {
                        Text(name).font(.chorus(12, .semibold)).frame(width: 60, alignment: .leading)
                        ForEach(InkCast.allCases, id: \.rawValue) { InkCharacter(kind: $0, pose: pose, shadow: true).frame(height: 110) }
                        ForEach(InkCast.allCases, id: \.rawValue) { InkCharacter(kind: $0, pose: pose).frame(height: 21) }
                    }
                }
            }
            try save("characters-\(scheme)", big, scheme: scheme)
        }
    }

    func testGlyphsAndChrome() throws {
        for scheme in [ColorScheme.light, .dark] {
            let v = VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    TrophyGlyph(won: false).frame(width: 16, height: 15)
                    TrophyGlyph(won: true).frame(width: 16, height: 15)
                    TrophyGlyph(won: false).frame(width: 70, height: 64)
                    TrophyGlyph(won: true).frame(width: 70, height: 64)
                    InkSendButtonLabel(enabled: true)
                    InkSendButtonLabel(enabled: false)
                    SparkleGlyph().fill(ChorusTheme.brandOrange).frame(width: 14, height: 14)
                }
                // Six panel headers as the app lays them out: each panel's character on the left.
                VStack(spacing: 4) {
                    ForEach(InkCast.allCases, id: \.rawValue) { kind in
                        HStack(spacing: 7) {
                            InkCharacter(kind: kind, pose: InkPose(happy: kind == .circle, mouth: kind == .square ? 0.7 : 0),
                                         fill: ChorusTheme.chrome(scheme))
                                .frame(width: 19, height: 22)
                            Text(["Gemini", "ChatGPT", "DeepSeek", "Claude", "Kimi", "Grok"][kind.rawValue]).font(.chorus(12, .semibold))
                            Spacer()
                            TrophyGlyph(won: kind == .triangle).frame(width: 17, height: 16)
                        }
                        .padding(.horizontal, 11).frame(width: 360, height: 30)
                        .background(Rectangle().fill(ChorusTheme.chrome(scheme)))
                    }
                }
                // The composer's controls: "…", "✦", layout · · · mic, send.
                HStack(spacing: 10) {
                    Image(nsImage: InkImages.dots).renderingMode(.template).foregroundColor(Ink.line(scheme))
                        .frame(width: 32, height: 26).inkChip()
                    Image(nsImage: InkImages.sparkle).frame(width: 32, height: 26).inkChip(orange: true)
                    LayoutGlyph(cols: 3, rows: 1, lineWidth: 1.5).foregroundColor(Ink.line(scheme))
                        .frame(width: 32, height: 26).inkChip()
                    Text("有问题，尽管问").font(.system(size: 13)).foregroundColor(.secondary)
                    Spacer()
                    InkMicGlyph().frame(width: 17, height: 17).frame(width: 32, height: 26).inkChip()
                    InkMicGlyph(recording: true).frame(width: 17, height: 17).frame(width: 32, height: 26).inkChip(orange: true)
                    InkSendButtonLabel(enabled: true)
                }
                .padding(.horizontal, 14).frame(width: 460, height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(ChorusTheme.chrome(scheme)))
                // The Compare chip (drawn the way ContentView draws around its menu).
                HStack(spacing: 5) {
                    SparkleGlyph().fill(ChorusTheme.brandOrange).frame(width: 12, height: 12)
                    Text("汇总").font(.chorus(12, .semibold))
                }
                .foregroundColor(ChorusTheme.brandOrange)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(ChorusTheme.brandOrange.opacity(0.12)))
                .overlay(Capsule().strokeBorder(ChorusTheme.brandOrange.opacity(0.32)))
                // Type: the rounded cascade next to the system face.
                VStack(alignment: .leading, spacing: 4) {
                    Text("圆体：汇总各家回答 · 新对话 · 加载失败 Compare 12").font(.chorus(15, .semibold))
                    Text("系统：汇总各家回答 · 新对话 · 加载失败 Compare 12").font(.system(size: 15, weight: .semibold))
                    Text("圆体 Medium：同时显示几个 AI").font(.chorus(13, .medium))
                }
            }
            try save("glyphs-\(scheme)", v, scheme: scheme)
        }
    }

    /// The quick input's leading glyph: the trio when asking everyone, one character for "@name".
    func testQuickInputGlyphs() throws {
        let row = { (icon: AnyView, text: String) in
            HStack(spacing: 10) {
                icon
                Text(text).font(.system(size: 22, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 18).frame(width: 520, height: 64)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.89, green: 0.87, blue: 0.84)))
        }
        let trio = AnyView(HStack(spacing: 1) {
            ForEach([InkCast.circle, .square, .triangle], id: \.rawValue) { InkCharacter(kind: $0, fill: .clear).frame(width: 18, height: 22) }
        }.padding(.top, -3))
        let one = AnyView(InkCharacter(kind: .square, fill: .clear).frame(width: 22, height: 26).padding(.top, -3))
        try save("quick-input-glyphs", VStack(spacing: 12) { row(trio, "这是什么书？"); row(one, "问 Gemini…") })
    }

    func testMenuBarGlyph() throws {
        let v = HStack(spacing: 20) {
            ForEach([false, true], id: \.self) { singing in
                VStack(spacing: 6) {
                    Image(nsImage: ChorusGlyph.circle(size: 18, filled: true, singing: singing)).renderingMode(.template)
                    Image(nsImage: ChorusGlyph.circle(size: 72, filled: true, singing: singing)).renderingMode(.template)
                }
            }
        }
        .foregroundColor(.black)
        try save("menubar-glyph", v)
    }

    func testLineupAndSheets() throws {
        try save("lineup", VStack(spacing: 12) {
            InkLineup().frame(height: 120)
            InkLineup(thinking: true).frame(height: 120)
        })
        try save("welcome", WelcomeSheet(onStart: {}))
        let working = SummaryModel()
        working.streaming = true
        try save("summary-working", SummarySheet(model: working, onClose: {}))
        try save("stats", StatsSheet(onClose: {}))
        for scheme in [ColorScheme.light, .dark] {
            try save("stats-rows-\(scheme)", StatsRows(rows: [
                .init(id: "chatgpt", name: "ChatGPT", wins: 21, shown: 38),
                .init(id: "x_chat_deepseek_com", name: "DeepSeek", wins: 13, shown: 38),
                .init(id: "gemini", name: "Gemini", wins: 4, shown: 20),
                .init(id: "api_groq", name: "Groq", wins: 0, shown: 3),
            ]).frame(width: 424).background(ChorusTheme.chrome(scheme)), scheme: scheme)
        }
        let done = SummaryModel()
        done.names = ["[A]": "ChatGPT", "[B]": "Claude", "[C]": "Gemini"]
        done.text = "## 结论\n起一个短而可爱的名字，Mochi 最合适。\n\n**分歧与判断**\n- [A] 和 [B] 选了零食名，[C] 选了骑士名。"
        try save("summary-done", SummarySheet(model: done, onClose: {}))
        // The finished text on its own: a snapshot can't draw inside the sheet's ScrollView.
        try save("summary-text", MarkdownText(text: done.shown).frame(width: 560).padding()
            .background(ChorusTheme.chrome(.light)))
    }
}
