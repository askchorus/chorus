import AppKit

/// "Send Feedback…": a new email to the address the landing page gives, with what a reply needs
/// to start from — the Chorus and macOS versions and the chip — already filled in under the
/// user's own words. Nothing is sent by Chorus; the user's mail app shows the draft.
enum Feedback {
    static let address = "smileduck@duck.com"

    /// "Chorus 0.2.6 · macOS 27.0.1 · Apple silicon"
    static func footer(appVersion: String, os: OperatingSystemVersion, appleSilicon: Bool) -> String {
        let osVersion = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        return "Chorus \(appVersion) · macOS \(osVersion) · \(appleSilicon ? "Apple silicon" : "Intel")"
    }

    /// A mailto: URL (RFC 6068). Subject and body are percent-encoded down to the unreserved
    /// characters, so an "&", "=", "+" or "#" in them can't cut the header short.
    static func mailURL(subject: String, body: String) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return URL(string: "mailto:\(address)?subject=\(enc(subject))&body=\(enc(body))")!
    }

    @MainActor static func compose() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        let info = footer(appVersion: version, os: ProcessInfo.processInfo.operatingSystemVersion, appleSilicon: appleSilicon)
        // Room to write above the details; CRLF is what RFC 6068 asks of line breaks in a body.
        let body = L("feedback.prompt") + "\r\n\r\n\r\n—\r\n" + info
        NSWorkspace.shared.open(mailURL(subject: L("feedback.subject"), body: body))
    }
}
