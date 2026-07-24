import Foundation
import Sparkle

/// Sparkle auto-update wiring. Feed + public key live in Info.plist (SUFeedURL / SUPublicEDKey);
/// the private key sits in the developer's login Keychain ("Private key for signing Sparkle
/// updates"). Updates are produced by scripts/release.sh, which signs the archive and appends an
/// appcast entry. With no reachable appcast (dev builds), a manual check just reports "no update"
/// — safe to keep wired in ad-hoc builds.
@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true → Sparkle schedules its own background checks per user consent
        // (it asks once on the second launch; defaults respect SUEnableAutomaticChecks).
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Explicit "检查更新…" from the menu — shows Sparkle's standard UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
