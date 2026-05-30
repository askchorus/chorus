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
        let shouldNotify: Bool
        switch mode {
        case "off":      shouldNotify = false
        case "always":   shouldNotify = true
        case "quickOnly": shouldNotify = (source == .quickInput)
        default:         shouldNotify = (source == .quickInput)
        }
        clog("batch complete — source=\(source), mode=\(mode), shouldNotify=\(shouldNotify)")
        guard shouldNotify else { return }

        // (Removed isChorusMainWindowKey() check — it created intermittent behavior
        //  when combined with foregroundMainOnSend. User wants consistent banners;
        //  if they don't want them while looking at Chorus, they can switch notifyMode.)

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

    private func isChorusMainWindowKey() -> Bool {
        for window in NSApp.windows where window.canBecomeMain {
            if window.isKeyWindow { return true }
        }
        return false
    }
}

/// Identifies where a broadcast originated. Used by the notifier to decide whether to alert.
enum BroadcastSource {
    case mainWindow
    case quickInput
}
