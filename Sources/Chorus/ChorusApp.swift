import SwiftUI
import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the app's lifetime so macOS won't put us into App Nap. Critical for keeping
    /// background WKWebViews responsive to streaming AI responses — otherwise WebContent
    /// processes get throttled when the window is occluded and the page JS doesn't process
    /// SSE chunks until the window is brought to the front again.
    private var antiNapToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force "regular" foreground app status — required for SPM-built executables
        // that lack a proper Info.plist. Without this, WKWebView can't receive keyboard input.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Apply saved appearance (System / Light / Dark) before windows show.
        AppearanceManager.apply(UserDefaults.standard.string(forKey: "appearance") ?? "system")

        antiNapToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled],
            reason: "Keep AI streaming alive when Chorus is in the background"
        )

        // Wire up global hotkey for the quick input window
        HotkeyManager.shared.onTrigger = {
            QuickInputWindowController.shared.toggle()
        }

        let storedKey  = UserDefaults.standard.object(forKey: "hotkeyKeyCode")    as? Int ?? Int(kVK_ANSI_C)
        let storedMods = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? Int(cmdKey | shiftKey)
        HotkeyManager.shared.register(
            keyCode: UInt32(storedKey),
            modifiers: UInt32(storedMods)
        )

        // Touch the store once so its init() wires up the completion script handler bridge
        _ = WebViewStore.shared

        // Request notification permission (system dialog shown once on first launch)
        CompletionNotifier.shared.requestAuthorizationIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Backstop: persist each panel's current conversation URL so we can reopen it next launch.
        WebViewStore.shared.saveAllSessionURLs()
    }
}

@main
struct ChorusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = WebViewStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1200, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}
