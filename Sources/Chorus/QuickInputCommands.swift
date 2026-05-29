import Foundation
import CoreServices
import AppKit

// MARK: - Prompt history (shared by the quick input and the main composer)

/// Persisted list of recently-broadcast prompts. ↑/↓ in either input recalls them.
enum PromptHistory {
    private static let key = "promptHistory"
    private static let maxCount = 50

    static func all() -> [String] {
        guard let s = UserDefaults.standard.string(forKey: key),
              let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    /// Append a sent prompt (oldest→newest), de-duping consecutive repeats, capped at maxCount.
    static func add(_ prompt: String) {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var arr = all()
        if arr.last == t { return }
        arr.append(t)
        if arr.count > maxCount { arr.removeFirst(arr.count - maxCount) }
        if let data = try? JSONEncoder().encode(arr), let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: key)
        }
    }
}

/// One step of history navigation. `index` is the current position (nil = not browsing yet),
/// `draft` is the user's in-progress text saved when they first entered history.
struct PromptHistoryResult {
    let prompt: String
    let index: Int?
    let draft: String
}

/// Compute the next history state. direction: -1 = older (↑), +1 = newer (↓).
/// Returns nil if the keypress should pass through (no history, or ↓ while not browsing).
func promptHistoryStep(direction: Int, current: String, index: Int?, draft: String) -> PromptHistoryResult? {
    let hist = PromptHistory.all()
    guard !hist.isEmpty else { return nil }
    if direction < 0 {  // older
        if index == nil {
            // Enter history: remember the current text as the draft to return to.
            return PromptHistoryResult(prompt: hist[hist.count - 1], index: hist.count - 1, draft: current)
        } else if let i = index, i > 0 {
            return PromptHistoryResult(prompt: hist[i - 1], index: i - 1, draft: draft)
        } else {
            return PromptHistoryResult(prompt: current, index: index, draft: draft)  // already oldest
        }
    } else {  // newer
        guard let i = index else { return nil }
        if i < hist.count - 1 {
            return PromptHistoryResult(prompt: hist[i + 1], index: i + 1, draft: draft)
        } else {
            return PromptHistoryResult(prompt: draft, index: nil, draft: draft)  // back to the draft
        }
    }
}

/// True if the focused text field editor's caret is at the very start (or no field editor).
func caretAtTextStart() -> Bool {
    guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
    let r = tv.selectedRange()
    return r.location == 0 && r.length == 0
}

/// True if the focused text field editor's caret is at the very end (or no field editor).
func caretAtTextEnd() -> Bool {
    guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
    let r = tv.selectedRange()
    return r.location + r.length >= (tv.string as NSString).length
}

/// Move the focused field editor's caret to the end (after a programmatic text change).
func moveCaretToTextEnd() {
    DispatchQueue.main.async {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let len = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: len, length: 0))
    }
}

/// Top-level commands a user can issue from the quick input. Anything that doesn't
/// match a `/`-prefixed command falls through to the default `.broadcast` behavior.
enum QuickCommand {
    case broadcast                  // default: send prompt to all visible AIs
    case help                       // /? or /help
}

enum CommandRouter {
    /// Parse the raw input into a structured command. Pure function.
    static func route(_ input: String) -> QuickCommand {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/?" || trimmed == "/help" {
            return .help
        }
        return .broadcast
    }
}

/// Help text shown when the user types `/?` — localized to the current language.
func helpText() -> String {
    currentLang() == "zh" ? helpTextZH : helpTextEN
}

private let helpTextEN = """
Tips

• Type a single word  → automatic Dictionary lookup (uses Dictionary.app)
  ↩ press Enter to dismiss after reading the definition
  ⎋ Esc also dismisses

• Words not in your dictionaries (e.g. slang, internet memes):
  no preview shows. Press ↩ Enter to broadcast and let the AIs explain.

• Any sentence / question → broadcast to all visible AIs

• /?  show this help
"""

private let helpTextZH = """
使用提示

• 输入单个词 → 自动查词典（使用 Dictionary.app）
  ↩ 看完释义后按回车关闭
  ⎋ Esc 也可关闭

• 词典里没有的词（如俚语、网络流行语）：
  不显示预览。按 ↩ 回车广播，让 AI 来解释。

• 任意句子 / 问题 → 广播给所有可见 AI

• /?  显示此帮助
"""

/// Heuristic: does this input look like a single-word lookup attempt
/// (rather than a sentence/question to broadcast)?
func isLikelyDictionaryQuery(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    // Must be a single token — no whitespace inside
    if trimmed.contains(where: { $0.isWhitespace }) { return false }
    // Reject sentence punctuation / slashes (commands)
    let punctChars: Set<Character> = ["?", "？", "。", "！", "!", ",", ",", "；", ";", ":", "：", "/"]
    if trimmed.contains(where: { punctChars.contains($0) }) { return false }
    // Reasonable length — most real words are under 40 chars
    if trimmed.count > 40 { return false }
    return true
}

/// Heuristic: is this word made of only ASCII letters / hyphen / apostrophe?
/// Used to decide whether to try the online English dictionary on a local-DCS miss.
func isLikelyEnglishWord(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "'") }
}

/// Quick-action prefixes used when the input contains text only.
let kDefaultChipPrompts: [String] = [
    "事实核查",
    "解释一下",
    "说的对吗",
    "翻译",
]

/// Quick-action prefixes shown when an image is attached. Tailored for vision tasks.
let kImageChipPrompts: [String] = [
    "解释这张图",
    "识别文字",
    "翻译图中文字",
    "描述一下",
    "图片出处",
]

/// Compose the new prompt body after a chip is tapped.
/// No trailing colon: for image-only it reads as a clean imperative ("解释这张图"),
/// and when there's text the blank line already separates instruction from content.
func applyChipPrefix(_ chip: String, to current: String) -> String {
    let content = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if content.isEmpty {
        return chip
    }
    return "\(chip)\n\n\(content)"
}

/// Parse a user-edited chip list (newline-separated, from Settings) into trimmed,
/// non-empty entries. Falls back to `fallback` when the field is empty/all-blank so a
/// cleared box doesn't hide every chip.
func parseChipList(_ raw: String, fallback: [String]) -> [String] {
    let items = raw
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return items.isEmpty ? fallback : items
}

/// Look up a word using macOS Dictionary Services — pulls from whichever
/// dictionaries the user has enabled in Dictionary.app (e.g. Oxford English,
/// 牛津 / 朗文, 现代汉语 / 朗文当代, 简明英汉 etc.). Local, no network.
func dictionaryDefinition(of word: String) -> String? {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let nsStr = trimmed as NSString
    let range = CFRangeMake(0, nsStr.length)
    guard let unmanaged = DCSCopyTextDefinition(nil, nsStr as CFString, range) else {
        return nil
    }
    let raw = unmanaged.takeRetainedValue() as String
    guard !raw.isEmpty else { return nil }
    return formatDictionaryDefinition(raw)
}

/// Break the wall-of-text DCS returns into a readable, structured layout.
/// DCS strips Dictionary.app's HTML but leaves Unicode structural markers:
///   `▸` — example
///   `①②③④⑤⑥⑦⑧⑨⑩⑪⑫` — sense numbers
///   `A. B. C. D.` — part-of-speech / major sections
///   `|` — separator between headword, pronunciation, body
private func formatDictionaryDefinition(_ raw: String) -> String {
    var s = raw

    // Major sections (A. noun, B. dogs plural noun, ...) — blank line before.
    for letter in ["A", "B", "C", "D", "E", "F"] {
        s = s.replacingOccurrences(of: " \(letter). ", with: "\n\n\(letter). ")
    }

    // Sense numbers (① ② ③ ...) — blank line before, two-space indent for clarity.
    for num in ["①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩","⑪","⑫","⑬","⑭","⑮"] {
        s = s.replacingOccurrences(of: " \(num) ", with: "\n  \(num) ")
        s = s.replacingOccurrences(of: " \(num)", with: "\n  \(num) ")  // catch trailing space variant
    }

    // Examples (▸) — newline with extra indent so they nest under their sense.
    s = s.replacingOccurrences(of: "▸", with: "\n     · ")

    // Tidy: collapse triple+ blank lines.
    while s.contains("\n\n\n") {
        s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    // Trim leading whitespace per line just in case.
    return s
}
