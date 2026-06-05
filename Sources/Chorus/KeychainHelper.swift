import Foundation
import Security

/// Minimal Keychain wrapper for storing API keys as generic passwords. We never put keys in
/// UserDefaults (plaintext); the Keychain keeps them encrypted and out of the prefs plist.
enum Keychain {
    private static let service = "com.smiletalker.chorus.apikeys"

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Local plaintext API-key store (Application Support/Chorus/apikeys.json). Used INSTEAD of the
/// Keychain so the app stops prompting for the keychain password on every launch — the app is
/// ad-hoc signed, so each rebuild looks like a "new app" to the Keychain and re-prompts.
///
/// ⚠️ DISTRIBUTION: this is plaintext on disk — fine for personal use, NOT for shipping to other
/// users. Before distributing, switch the three call sites (APIProvider.apiKey,
/// APIProviderRegistry.add/remove) back from `KeyStore` to `Keychain`, and do proper Developer-ID
/// signing so the Keychain stops re-prompting.
enum KeyStore {
    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let d = dir.appendingPathComponent("Chorus", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("apikeys.json")
    }
    private static func load() -> [String: String] {
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }
    private static func save(_ dict: [String: String]) {
        guard let url, let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func get(account: String) -> String? {
        if let v = load()[account], !v.isEmpty { return v }
        // One-time migration: pull an existing key out of the old Keychain store (prompts once),
        // copy it to the file, then the file is used forever after — no more prompts.
        if let v = Keychain.get(account: account), !v.isEmpty {
            set(v, account: account)
            return v
        }
        return nil
    }
    static func set(_ value: String, account: String) {
        var d = load(); d[account] = value; save(d)
    }
    static func delete(account: String) {
        var d = load(); d.removeValue(forKey: account); save(d)
        Keychain.delete(account: account)   // also clear any stale Keychain copy
    }
}
