import Foundation

/// Looks up English words against https://api.dictionaryapi.dev — free,
/// no API key. Returns both a pre-formatted definition string and (when
/// available) a Wikimedia Commons audio URL with a real human recording.
/// In-memory cache + in-flight de-dup so live typing doesn't fire N requests.
@MainActor
final class OnlineDictionary {
    static let shared = OnlineDictionary()

    private var cache: [String: OnlineLookupResult] = [:]
    private var negativeCache: Set<String> = []                       // words known to have no entry
    private var inflight: [String: Task<OnlineLookupResult?, Never>] = [:]

    private init() {}

    /// Look up `word`; returns nil if no entry, or on network failure.
    func lookup(_ word: String) async -> OnlineLookupResult? {
        let key = word.lowercased()
        if let cached = cache[key] { return cached }
        if negativeCache.contains(key) { return nil }
        if let pending = inflight[key] { return await pending.value }

        let task = Task<OnlineLookupResult?, Never> { [weak self] in
            await self?.doFetch(key: key) ?? nil
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func doFetch(key: String) async -> OnlineLookupResult? {
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                negativeCache.insert(key)
                return nil
            }
            let entries = try JSONDecoder().decode([DictAPIEntry].self, from: data)
            guard !entries.isEmpty else {
                negativeCache.insert(key)
                return nil
            }

            let formatted = format(entries: entries)
            let audioURL = entries
                .flatMap { $0.phonetics ?? [] }
                .compactMap { ph -> URL? in
                    guard let a = ph.audio, !a.isEmpty else { return nil }
                    return URL(string: a)
                }
                .first

            let result = OnlineLookupResult(formatted: formatted, audioURL: audioURL)
            cache[key] = result
            return result
        } catch {
            // Network / decode error — don't poison the negative cache
            return nil
        }
    }

    // MARK: Formatting

    private func format(entries: [DictAPIEntry]) -> String {
        guard let first = entries.first else { return "" }
        var s = first.word

        // First non-empty phonetic transcription
        let phonetic = first.phonetic ?? entries
            .flatMap { $0.phonetics ?? [] }
            .compactMap { $0.text }
            .first(where: { !$0.isEmpty })
        if let p = phonetic, !p.isEmpty {
            s += "  \(p)"
        }
        s += "\n"

        for entry in entries {
            for meaning in entry.meanings ?? [] {
                let pos = meaning.partOfSpeech ?? ""
                if !pos.isEmpty {
                    s += "\n\(pos)\n"
                }
                for (idx, def) in (meaning.definitions ?? []).enumerated() {
                    let num = circleNumber(idx + 1)
                    if let d = def.definition {
                        s += "  \(num) \(d)\n"
                    }
                    if let ex = def.example, !ex.isEmpty {
                        s += "       · \(ex)\n"
                    }
                }
            }
        }
        // Tidy trailing newlines
        while s.hasSuffix("\n\n") { s.removeLast() }
        return s
    }

    private func circleNumber(_ n: Int) -> String {
        let circles = ["①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩","⑪","⑫"]
        return n <= circles.count ? circles[n-1] : "\(n)."
    }
}

struct OnlineLookupResult {
    let formatted: String
    let audioURL: URL?
}

// MARK: - API response shape

private struct DictAPIEntry: Codable {
    let word: String
    let phonetic: String?
    let phonetics: [DictAPIPhonetic]?
    let meanings: [DictAPIMeaning]?
}
private struct DictAPIPhonetic: Codable {
    let text: String?
    let audio: String?
}
private struct DictAPIMeaning: Codable {
    let partOfSpeech: String?
    let definitions: [DictAPIDefinition]?
}
private struct DictAPIDefinition: Codable {
    let definition: String?
    let example: String?
}
