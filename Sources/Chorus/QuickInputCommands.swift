import Foundation
import CoreServices

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

/// Stable help text shown when user types `/?`.
let kHelpText = """
Tips

• Type a single word  → automatic Dictionary lookup (uses Dictionary.app)
  ↩ press Enter to dismiss after reading the definition
  ⎋ Esc also dismisses

• Words not in your dictionaries (e.g. slang, 网络流行语):
  no preview shows. Press ↩ Enter to broadcast and let the AIs explain.

• Any sentence / question → broadcast to all visible AIs

• /?  show this help
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
