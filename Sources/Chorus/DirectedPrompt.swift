import Foundation

/// The "@name question" syntax shared by both composers: a leading @-token picks which
/// on-screen panels receive the message. Pure — the store supplies the candidates — so the
/// matching rules are unit-tested (Tests/ChorusTests/DirectedPromptTests.swift).
enum DirectedPrompt {
    struct Candidate: Equatable {
        let id: String     // provider key / API id — what `broadcast(targets:)` filters on
        let name: String   // display name, which is what the user actually types
    }

    /// Resolution order:
    ///   1. Exact match on display name or id (case-insensitive). Hits EVERY panel with that
    ///      name — a web "DeepSeek" and an API "DeepSeek" both answer "@deepseek".
    ///   2. Prefix match on display name, honoured only when unambiguous: every match must share
    ///      one name. "@gem" → Gemini; "@deep" → both DeepSeeks; "@c" with ChatGPT and Claude on
    ///      screen resolves to nothing rather than silently picking whichever came first.
    ///   3. Otherwise the text passes through untouched — an email address, a bare "@name" with
    ///      no question, or a typo must never eat the message.
    static func resolve(_ raw: String, candidates: [Candidate]) -> (targets: Set<String>?, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"), trimmed.count > 1 else { return (nil, raw) }
        let afterAt = trimmed.dropFirst()
        let token = afterAt.prefix { !$0.isWhitespace }
        let rest = afterAt.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !rest.isEmpty else { return (nil, raw) }   // "@gemini" alone isn't a question
        let needle = token.lowercased()

        let exact = candidates.filter { $0.name.lowercased() == needle || $0.id.lowercased() == needle }
        if !exact.isEmpty { return (Set(exact.map(\.id)), rest) }

        let prefixed = candidates.filter { $0.name.lowercased().hasPrefix(needle) }
        let names = Set(prefixed.map { $0.name.lowercased() })
        if names.count == 1 { return (Set(prefixed.map(\.id)), rest) }

        return (nil, raw)
    }
}
