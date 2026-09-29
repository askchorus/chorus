import Foundation
import UserNotifications
import AppKit
import os

/// Use os.Logger (unified logging) — NSLog from SPM-built apps doesn't reliably surface
/// in `log show`. Logger with explicit .public privacy does.
let chorusLog = Logger(subsystem: "com.smiletalker.chorus", category: "notif")

func clog(_ msg: String) {
    chorusLog.notice("[Chorus.Notif] \(msg, privacy: .public)")
}

@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()

    private var didRequestAuth = false

    private override init() {
        super.init()
        // CRITICAL: install ourselves as delegate so notifications display even when
        // Chorus is the frontmost app. macOS suppresses banners for foreground apps
        // unless willPresent explicitly says otherwise.
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        clog("willPresent — id=\(notification.request.identifier)")
        completionHandler([.banner, .sound])
    }

    /// Request notification permission. Idempotent — only triggers system dialog the first time.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let errStr = error?.localizedDescription ?? "nil"
            clog("auth requested — granted: \(granted), error: \(errStr)")
        }
    }

    /// Fire a test notification immediately — bypasses completion-detection logic so we can
    /// isolate whether permission/delivery itself is broken.
    func sendTestNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            clog("test — authStatus=\(settings.authorizationStatus.rawValue), alert=\(settings.alertSetting.rawValue), sound=\(settings.soundSetting.rawValue)")
        }

        let content = UNMutableNotificationContent()
        content.title = L("notif.testTitle")
        content.body = L("notif.testBody")
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "chorus-test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(req) { error in
            let errStr = error?.localizedDescription ?? "nil"
            clog("test posted — error: \(errStr)")
        }
    }

    /// Called when all visible AIs in a broadcast batch have finished streaming.
    /// `source` indicates whether the broadcast originated from the main window or the quick input.
    func handleBatchComplete(source: BroadcastSource) {
        let mode = UserDefaults.standard.string(forKey: "notifyMode") ?? "quickOnly"
        var shouldNotify: Bool
        switch mode {
        case "off":      shouldNotify = false
        case "always":   shouldNotify = true
        case "quickOnly": shouldNotify = (source == .quickInput)
        default:         shouldNotify = (source == .quickInput)
        }
        // An agent question is answered back through the bridge; a banner for something the user
        // never typed is pure noise.
        if source == .agent { shouldNotify = false }
        clog("batch complete — source=\(source), mode=\(mode), shouldNotify=\(shouldNotify)")
        guard shouldNotify else { return }

        let content = UNMutableNotificationContent()
        content.title = "Chorus"
        content.body = completionNotificationBody()  // rotating minimal line, localized
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(req) { error in
            let errStr = error?.localizedDescription ?? "nil"
            clog("real notification posted — error: \(errStr)")
        }
    }

    /// A comparison finished while Chorus wasn't frontmost. The user started it and went
    /// elsewhere, so it notifies in every mode but "off".
    func postComparisonReady() {
        guard (UserDefaults.standard.string(forKey: "notifyMode") ?? "quickOnly") != "off" else { return }
        let content = UNMutableNotificationContent()
        content.title = L("summary.ready")
        content.body = L("summary.readyBody")
        content.sound = .default
        let req = UNNotificationRequest(identifier: "chorus-compare-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            clog("comparison-ready notification posted — error: \(error?.localizedDescription ?? "nil")")
        }
    }
}

/// Identifies where a broadcast originated. Used by the notifier to decide whether to alert.
enum BroadcastSource {
    case mainWindow
    case quickInput
    /// Asked by a coding agent through the local bridge. Never raises a completion notification —
    /// the agent is already waiting on the reply, and a banner for a question the user didn't type
    /// would just be noise.
    case agent
}
