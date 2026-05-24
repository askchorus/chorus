import Foundation

/// Fetches one-paragraph summaries from Wikipedia's REST summary endpoint.
/// Great for proper nouns / products / companies / concepts that general
/// dictionaries don't cover (Claude, Anthropic, Kubernetes, etc.).
/// Free, no API key. In-memory cache + in-flight de-dup.
@MainActor
final class WikipediaSummary {
    static let shared = WikipediaSummary()

    private var cache: [String: String] = [:]
    private var negativeCache: Set<String> = []
    private var inflight: [String: Task<String?, Never>] = [:]

    private init() {}

    func lookup(_ term: String) async -> String? {
        let key = term.lowercased()
        if let cached = cache[key] { return cached }
        if negativeCache.contains(key) { return nil }
        if let pending = inflight[key] { return await pending.value }

        let task = Task<String?, Never> { [weak self] in
            await self?.doFetch(term: term) ?? nil
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func doFetch(term: String) async -> String? {
        // Wikipedia titles use spaces → underscores; we just URL-encode the whole thing.
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        // Wikipedia REST politely asks for a User-Agent. Anonymous default works
        // but identifying ourselves is good citizenship and avoids occasional throttling.
        req.setValue("Chorus/0.1 (https://github.com/smieltalker/chorus-mac)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                negativeCache.insert(term.lowercased())
                return nil
            }
            let resp = try JSONDecoder().decode(WikiResponse.self, from: data)
            guard let extract = resp.extract, !extract.isEmpty else {
                negativeCache.insert(term.lowercased())
                return nil
            }
            // Compose readable formatted output. Title, optional description, then the summary.
            var s = resp.title
            if let desc = resp.description, !desc.isEmpty {
                s += "  ·  \(desc)"
            }
            s += "\n\n\(extract)"
            cache[term.lowercased()] = s
            return s
        } catch {
            return nil  // don't poison cache on transient errors
        }
    }
}

private struct WikiResponse: Codable {
    let title: String
    let extract: String?
    let description: String?
}
