import Foundation

/// A user-configured LLM endpoint reached via an OpenAI-compatible chat-completions API.
/// One format covers OpenAI, DeepSeek, Groq, OpenRouter, SiliconFlow, and local servers
/// (Ollama / LM Studio). The API key is NOT stored here — it lives in the Keychain, keyed by id.
struct APIProvider: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var baseURL: String   // e.g. https://api.openai.com/v1  (no trailing /chat/completions)
    var model: String     // e.g. gpt-4o, deepseek-chat, llama3.2

    var apiKey: String? { Keychain.get(account: "apikey_\(id)") }
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
        APIPreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",     model: "",                  needsKey: true),
        APIPreset(name: "硅基流动",    baseURL: "https://api.siliconflow.cn/v1",    model: "",                  needsKey: true),
        APIPreset(name: "Ollama",     baseURL: "http://localhost:11434/v1",        model: "llama3.2",          needsKey: false),
        APIPreset(name: "LM Studio",  baseURL: "http://localhost:1234/v1",         model: "",                  needsKey: false),
    ]

    static func all() -> [APIProvider] {
        guard let s = UserDefaults.standard.string(forKey: storeKey),
              let data = s.data(using: .utf8),
              let list = try? JSONDecoder().decode([APIProvider].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [APIProvider]) {
        guard let data = try? JSONEncoder().encode(list),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: storeKey)
    }

    /// Add a provider. Returns false if name/baseURL are unusable. Stores the key in Keychain.
    @discardableResult
    static func add(name: String, baseURL: String, model: String, apiKey: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "apikey_\(id)")
        return true
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
        Keychain.delete(account: "apikey_\(id)")
    }
}
