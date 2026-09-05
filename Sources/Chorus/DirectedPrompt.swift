import Foundation

/// The "@name question" syntax shared by both composers: a leading @-token picks which
/// on-screen panels receive the message. Pure — the store supplies the candidates — so the
/// matching rules are unit-tested (Tests/ChorusTests/DirectedPromptTests.swift).
enum DirectedPrompt {
    struct Candidate: Equatable {
        let id: String          // provider key / API id — what `broadcast(targets:)` filters on
        let name: String        // display name, which is what the user actually types
        var host: String = ""   // site host for the accent colour (empty for API panels)
    }

    /// One picker row / one chip: a display name and every panel that answers to it. A web
    /// "DeepSeek" and an API "DeepSeek" are ONE option, not two look-alike rows.
    struct Target: Equatable {
        let name: String
        let ids: Set<String>
        let key: String    // first panel's key — favicon / accent lookup
        let host: String
    }

    /// Candidates grouped by display name (first-seen order), narrowed to those whose name or id
    /// starts with `query` (case-insensitive). Empty query → everything.
    static func options(_ candidates: [Candidate], query: String = "") -> [Target] {
        let q = query.lowercased()
        var order: [String] = []
        var groups: [String: (name: String, ids: Set<String>, key: String, host: String)] = [:]
        for c in candidates {
            let k = c.name.lowercased()
            if !q.isEmpty && !k.hasPrefix(q) && !c.id.lowercased().hasPrefix(q) { continue }
            if groups[k] == nil {
                order.append(k)
                groups[k] = (c.name, [], c.id, c.host)
            }
            groups[k]!.ids.insert(c.id)
        }
        return order.map { k in
            let g = groups[k]!
            return Target(name: g.name, ids: g.ids, key: g.key, host: g.host)
        }
    }

    /// Strict resolution of a typed token — the path for "@name " typed straight through without
    /// touching the picker. An exact name wins (hitting every panel with that name); an exact id
    /// hits just that panel; otherwise a prefix is honoured only when it narrows to ONE option —
    /// "@c" with ChatGPT and Claude on screen resolves to nothing rather than silently picking
    /// whichever came first.
    static func target(for token: String, in candidates: [Candidate]) -> Target? {
        let needle = token.lowercased()
        guard !needle.isEmpty else { return nil }
        if let exact = options(candidates).first(where: { $0.name.lowercased() == needle }) { return exact }
        if let byId = candidates.first(where: { $0.id.lowercased() == needle }) {
            return Target(name: byId.name, ids: [byId.id], key: byId.id, host: byId.host)
        }
        let narrowed = options(candidates, query: needle)
        return narrowed.count == 1 ? narrowed[0] : nil
    }

    /// "@gemini 展开说说第二点" → (["gemini"], "展开说说第二点"). Anything that doesn't resolve —
    /// an email address, a bare "@name" with no question, an ambiguous or unknown name — passes
    /// through untouched, so a mention can never eat the message.
    static func resolve(_ raw: String, candidates: [Candidate]) -> (targets: Set<String>?, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"), trimmed.count > 1 else { return (nil, raw) }
        let afterAt = trimmed.dropFirst()
        let token = afterAt.prefix { !$0.isWhitespace }
        let rest = afterAt.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !rest.isEmpty else { return (nil, raw) }   // "@gemini" alone isn't a question
        guard let t = target(for: String(token), in: candidates) else { return (nil, raw) }
        return (t.ids, rest)
    }

    /// The mention currently being typed, if the composer holds "@…" and nothing after it:
    /// "@" → "", "@gem" → "gem", "@gemini 问题" → nil (a space ended the token). Drives the picker.
    static func pendingMention(in text: String) -> String? {
        let t = text.drop(while: { $0.isWhitespace })
        guard t.first == "@" else { return nil }
        let token = t.dropFirst()
        guard !token.contains(where: { $0.isWhitespace }), token.count <= 30 else { return nil }
        return String(token)
    }

    /// "@name" + space typed straight through: `previous` held a pending mention and `current`
    /// is exactly that mention followed by one space. Returns the token so it can become a chip.
    static func completedMention(previous: String, current: String) -> String? {
        guard let token = pendingMention(in: previous), !token.isEmpty,
              current == previous + " " else { return nil }
        return token
    }
}
