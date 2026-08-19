import SwiftUI
import Foundation

struct Provider: Identifiable {
    let key: String
    let name: String
    let url: URL
    var isBuiltIn: Bool = false
    var id: String { key }
}

/// Codable form for persisting user-added providers in UserDefaults.
private struct ProviderDTO: Codable {
    let key: String
    let name: String
    let url: String
}

/// Single source of truth for the AI panels: three tuned built-ins plus any the user adds.
/// Built-ins have hand-tuned input/send/upload selectors; custom ones broadcast text via a
/// generic strategy (contenteditable/textarea + Send button or Enter).
enum ProviderRegistry {
    static let customKey = "customProviders"

    static let builtIn: [Provider] = [
        Provider(key: "chatgpt", name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!,        isBuiltIn: true),
        Provider(key: "claude",  name: "Claude",  url: URL(string: "https://claude.ai/")!,          isBuiltIn: true),
        Provider(key: "gemini",  name: "Gemini",  url: URL(string: "https://gemini.google.com/")!,  isBuiltIn: true),
    ]

    /// Real, ready-to-add AIs surfaced as one-click "Quick add" chips in Settings, so the
    /// user doesn't have to look up URLs. (They still log in once inside the new panel.)
    /// Real, ready-to-add AIs surfaced as one-click "Quick add" chips in Settings, so the
    /// user doesn't have to look up URLs. (They still log in once inside the new panel.)
    ///
    /// `cnOnly` marks services with no meaningful presence outside China — they stay in the list
    /// for everyone (a Chinese speaker running the English UI still wants 豆包), but sort last
    /// under English so the chips lead with names that audience recognises. Nothing is hidden and
    /// nothing is auto-removed: the default panels are ChatGPT/Claude/Gemini either way, and these
    /// only ever appear because the user added them.
    struct Preset {
        let name: String        // display name in Chinese UI
        let nameEN: String      // display name in English UI
        let url: String
        let cnOnly: Bool
    }

    static let presetList: [Preset] = [
        Preset(name: "DeepSeek",   nameEN: "DeepSeek",   url: "https://chat.deepseek.com/",   cnOnly: false),
        Preset(name: "Kimi",       nameEN: "Kimi",       url: "https://www.kimi.com/",        cnOnly: false),
        Preset(name: "Grok",       nameEN: "Grok",       url: "https://grok.com/",            cnOnly: false),
        Preset(name: "Perplexity", nameEN: "Perplexity", url: "https://www.perplexity.ai/",   cnOnly: false),
        Preset(name: "千问",        nameEN: "Qwen",       url: "https://www.tongyi.com/",      cnOnly: true),
        Preset(name: "豆包",        nameEN: "Doubao",     url: "https://www.doubao.com/chat/", cnOnly: true),
        Preset(name: "腾讯元宝",     nameEN: "Yuanbao",    url: "https://yuanbao.tencent.com/", cnOnly: true),
        Preset(name: "Le Chat",    nameEN: "Le Chat",    url: "https://chat.mistral.ai/",     cnOnly: false),
        Preset(name: "Manus",      nameEN: "Manus",      url: "https://manus.im/",            cnOnly: false),
        Preset(name: "Genspark",   nameEN: "Genspark",   url: "https://www.genspark.ai/",     cnOnly: false),
        Preset(name: "MiniMax",    nameEN: "MiniMax",    url: "https://chat.minimaxi.com/",   cnOnly: false),
        Preset(name: "GLM",        nameEN: "GLM",        url: "https://chat.z.ai/",           cnOnly: false),
    ]

    /// Presets for the current UI language: Chinese keeps the authored order (DeepSeek and Kimi
    /// lead — they are the popular picks there); English keeps the same set but sorts the
    /// China-only services last and shows their romanized names.
    static var presets: [(name: String, url: String)] {
        guard currentLang() == "en" else {
            return presetList.map { (name: $0.name, url: $0.url) }
        }
        let ordered = presetList.filter { !$0.cnOnly } + presetList.filter { $0.cnOnly }
        return ordered.map { (name: $0.nameEN, url: $0.url) }
    }

    static func decode(_ raw: String) -> [Provider] {
        guard let data = raw.data(using: .utf8),
              let dtos = try? JSONDecoder().decode([ProviderDTO].self, from: data) else { return [] }
        return dtos.compactMap { dto in
            guard let url = URL(string: dto.url) else { return nil }
            return Provider(key: dto.key, name: dto.name, url: url, isBuiltIn: false)
        }
    }

    static func custom() -> [Provider] {
        decode(UserDefaults.standard.string(forKey: customKey) ?? "")
    }

    static func all() -> [Provider] { builtIn + custom() }

    private static func saveCustom(_ providers: [Provider]) {
        let dtos = providers.map { ProviderDTO(key: $0.key, name: $0.name, url: $0.url.absoluteString) }
        guard let data = try? JSONEncoder().encode(dtos),
              let s = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: customKey)
    }

    /// Add a custom provider from a name + URL string. Returns false if the URL is unusable.
    @discardableResult
    static func addCustom(name: String, urlString: String) -> Bool {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? host : trimmedName
        // Stable unique key from the host.
        let base = host.replacingOccurrences(of: ".", with: "_")
        let existing = Set(all().map(\.key))
        var key = "x_" + base
        var n = 2
        while existing.contains(key) { key = "x_\(base)_\(n)"; n += 1 }
        var list = custom()
        list.append(Provider(key: key, name: displayName, url: url, isBuiltIn: false))
        saveCustom(list)
        return true
    }

    static func removeCustom(key: String) {
        saveCustom(custom().filter { $0.key != key })
    }
}

