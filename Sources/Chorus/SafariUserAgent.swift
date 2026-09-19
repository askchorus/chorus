import AppKit

/// The suffix real Safari appends to WebKit's own User-Agent prefix:
///   WebKit:  Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)
///   Safari:  … + " Version/27.0 Safari/605.1.15"
///
/// The panels must look like the Safari that matches the ENGINE they run on — Cloudflare and
/// Google sign-in both compare the claimed browser with what the engine can actually do. A
/// hard-coded string goes stale with every OS release (it sat at Version/17.5 while the system
/// shipped Safari 27), so the version is read from the installed Safari at launch and handed to
/// WebKit through `applicationNameForUserAgent`, leaving the prefix to WebKit itself.
enum SafariUserAgent {
    /// Pure: the application-name suffix for a given Safari version, falling back to the Safari
    /// that ships with `osMajor` when the version is missing or not a plain dotted number.
    static func applicationName(safariVersion: String?, osMajor: Int) -> String {
        let v = safariVersion.flatMap { isPlainVersion($0) ? $0 : nil } ?? bundledSafariVersion(osMajor: osMajor)
        return "Version/\(v) Safari/605.1.15"
    }

    /// "27.0", "17.4.1" — one to three numeric components, nothing else (the value ends up in an
    /// HTTP header, so anything unexpected is rejected rather than forwarded).
    static func isPlainVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && $0.allSatisfy(\.isASCII) }
    }

    /// Safari's version numbers follow macOS since 26; before that they ran two or three ahead.
    static func bundledSafariVersion(osMajor: Int) -> String {
        switch osMajor {
        case 26...: return "\(osMajor).0"
        case 15:    return "18.0"
        case 14:    return "17.0"
        default:    return "16.0"   // macOS 13, the deployment floor
        }
    }

    /// The installed Safari's marketing version, or nil if it can't be read.
    static func installedSafariVersion() -> String? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            ?? URL(fileURLWithPath: "/Applications/Safari.app")
        let plist = url.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
    }

    /// What the panels use.
    static var applicationName: String {
        applicationName(safariVersion: installedSafariVersion(),
                        osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}
