import Foundation

/// A user-configured LLM endpoint reached via an OpenAI-compatible chat-completions API.
/// One format covers OpenAI, DeepSeek, Groq, OpenRouter, SiliconFlow, and local servers
/// (Ollama / LM Studio). The API key is NOT stored here — it lives in the Keychain, keyed by id.
struct APIProvider: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var baseURL: String   // e.g. https://api.openai.com/v1  (no trailing /chat/completions)
    var model: String     // e.g. gpt-4o, deepseek-chat, llama3.2

    var apiKey: String? { KeyStore.get(account: "apikey_\(id)") }
}

/// One-tap presets that prefill the add form (baseURL + a sensible default model). Local ones
/// (Ollama / LM Studio) need no key.
struct APIPreset {
    let name: String
    let baseURL: String
    let model: String
    let needsKey: Bool
}

enum APIProviderRegistry {
    static let storeKey = "apiProviders"

    static let presets: [APIPreset] = [
        APIPreset(name: "OpenAI",     baseURL: "https://api.openai.com/v1",        model: "gpt-4o",            needsKey: true),
        APIPreset(name: "DeepSeek",   baseURL: "https://api.deepseek.com/v1",      model: "deepseek-chat",     needsKey: true),
        APIPreset(name: "Groq",       baseURL: "https://api.groq.com/openai/v1",   model: "llama-3.3-70b-versatile", needsKey: true),
        // Gemini speaks OpenAI's protocol at this endpoint. Worth a preset of its own: when the
        // consumer web app is geo-blocked (a flagged proxy IP gets "not supported in your
        // country"), the API endpoint stays reachable on the same network — so an API panel is
        // the way to keep Gemini in the lineup without re-routing anything.
        APIPreset(name: "Gemini",     baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-3.5-flash", needsKey: true),
        APIPreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",     model: "",                  needsKey: true),
        APIPreset(name: "硅基流动",    baseURL: "https://api.siliconflow.cn/v1",    model: "",                  needsKey: true),
        APIPreset(name: "Ollama",     baseURL: "http://localhost:11434/v1",        model: "llama3.2",          needsKey: false),
        APIPreset(name: "LM Studio",  baseURL: "http://localhost:1234/v1",         model: "",                  needsKey: false),
    ]

    /// Services people name their API panels after, spelled the way the services spell them.
    /// Presets first, so a preset's own spelling always wins.
    private static let knownNames: [String: String] = {
        var map: [String: String] = [:]
        let extra = ["Anthropic", "Claude", "Mistral", "Moonshot", "Kimi", "Qwen", "xAI", "Grok",
                     "Perplexity", "Together", "Fireworks", "Cerebras", "SiliconFlow", "Zhipu", "GLM",
                     "MiniMax", "Doubao", "Azure OpenAI"]
        for name in presets.map(\.name) + extra where map[name.lowercased()] == nil {
            map[name.lowercased()] = name
        }
        map["lmstudio"] = "LM Studio"
        return map
    }()

    /// A panel named just "deepseek" or "GROQ" shows as "DeepSeek" / "Groq", matching the web
    /// panel of the same AI and the presets. Any other name — "deepseek reasoner", "My Groq",
    /// "硅基流动" — is the user's own and stays exactly as typed.
    static func canonicalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return knownNames[trimmed.lowercased()] ?? trimmed
    }

    /// Decode a providers list from its stored JSON string. Views can call this with their
    /// `@AppStorage("apiProviders")` value so SwiftUI tracks the dependency and updates live.
    /// Names come back canonical (see `canonicalName`), so every menu, header and @-picker agrees.
    static func decode(_ raw: String) -> [APIProvider] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([APIProvider].self, from: data) else { return [] }
        return list.map { var p = $0; p.name = canonicalName(p.name); return p }
    }

    static func all() -> [APIProvider] {
        decode(UserDefaults.standard.string(forKey: storeKey) ?? "")
    }

    private static func save(_ list: [APIProvider]) {
        guard let data = try? JSONEncoder().encode(list),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: storeKey)
    }

    /// Add a provider. Returns false if name/baseURL are unusable. Stores the key in Keychain.
    @discardableResult
    static func add(name: String, baseURL: String, model: String, apiKey: String) -> Bool {
        let trimmedName = canonicalName(name)
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        guard !trimmedName.isEmpty, !url.isEmpty, URL(string: url) != nil else { return false }
        // Stable unique id.
        let base = "api_" + trimmedName.lowercased().replacingOccurrences(of: " ", with: "_")
        let existing = Set(all().map(\.id))
        var id = base, n = 2
        while existing.contains(id) { id = "\(base)_\(n)"; n += 1 }
        let p = APIProvider(id: id, name: trimmedName, baseURL: url,
                            model: model.trimmingCharacters(in: .whitespacesAndNewlines))
        var list = all(); list.append(p); save(list)
        KeyStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "apikey_\(id)")
        return true
    }

    /// Edit an existing provider in place (keeps its id, so chat history + visibility persist).
    /// The key is replaced ONLY if `apiKey` is non-empty — blank means "keep the current key".
    @discardableResult
    static func update(id: String, name: String, baseURL: String, model: String, apiKey: String) -> Bool {
        let trimmedName = canonicalName(name)
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        guard !trimmedName.isEmpty, !url.isEmpty, URL(string: url) != nil else { return false }
        var list = all()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return false }
        list[idx].name = trimmedName
        list[idx].baseURL = url
        list[idx].model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        save(list)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { KeyStore.set(key, account: "apikey_\(id)") }
        return true
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
        KeyStore.delete(account: "apikey_\(id)")
    }
}
