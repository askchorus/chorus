import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Held for the app's lifetime so macOS won't put us into App Nap. Critical for keeping
    /// background WKWebViews responsive to streaming AI responses — otherwise WebContent
    /// processes get throttled when the window is occluded and the page JS doesn't process
    /// SSE chunks until the window is brought to the front again.
    private var antiNapToken: NSObjectProtocol?

    /// Menu-bar status item (built manually — SwiftUI's MenuBarExtra doesn't reliably render
    /// alongside this app's AppKit lifecycle setup).
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force "regular" foreground app status — required for SPM-built executables
        // that lack a proper Info.plist. Without this, WKWebView can't receive keyboard input.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Apply saved appearance (System / Light / Dark) before windows show.
        AppearanceManager.apply(UserDefaults.standard.string(forKey: "appearance") ?? "light")

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
        // Keeper window must exist and be ordered in BEFORE any ⌘H (see prepareKeeper's doc).
        WebViewStore.shared.prepareKeeper()

        // Start Sparkle at launch so its scheduled background checks run (user consent is asked
        // once by Sparkle itself); a dev build without a reachable appcast just stays quiet.
        _ = UpdateManager.shared

        // Keeper triggers for the two window-level paths that hide pages WITHOUT hiding the app:
        // minimize (yellow button) and close (red button, app stays in the menu bar). Restore is
        // driven by applicationDidBecomeActive/didUnhide + windowDidDeminiaturize below.
        NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, WebViewStore.shared.windowHostsPanels(w) else { return }
                clog("APP window miniaturized")
                WebViewStore.shared.adoptIntoKeeper()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard note.object is NSWindow else { return }
                clog("APP window deminiaturized")
                WebViewStore.shared.restoreFromKeeper()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, WebViewStore.shared.windowHostsPanels(w) else { return }
                clog("APP main window closing — adopting panels into keeper")
                WebViewStore.shared.adoptIntoKeeper()
                // The always-present keeper means AppKit never sees "last window closed", so the
                // quit-on-close behavior (menu-bar icon disabled) must be triggered manually.
                if !(UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true) {
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }

        // Request notification permission (system dialog shown once on first launch)
        CompletionNotifier.shared.requestAuthorizationIfNeeded()

        // Menu bar: build the status item, keep its icon in sync with streaming state, and
        // add/remove it live when the user toggles the setting.
        syncMenuBarVisibility()
        // Both publishers are delivered on the main run loop, so the work is genuinely on the
        // main actor — assumeIsolated lets us call the @MainActor helpers without an async hop.
        WebViewStore.shared.$streamingKeys
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateStatusIcon() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.syncMenuBarVisibility() } }
            .store(in: &cancellables)
    }

    // Timestamp app active-state transitions — cheap, and lining them up against completion logs
    // is how the minimize-freeze was proven. Kept as permanent diagnostics. Hide/unhide also
    // drive the keep-alive keeper window (see WebViewStore.adoptIntoKeeper).
    func applicationDidResignActive(_ n: Notification)  { clog("APP resignActive (another app frontmost)") }
    func applicationDidBecomeActive(_ n: Notification) {
        clog("APP becomeActive (Chorus frontmost)")
        WebViewStore.shared.restoreFromKeeper()   // covers unhide, deminiaturize and reopen paths
    }
    func applicationDidHide(_ n: Notification) {
        clog("APP didHide (⌘H — windows ordered out)")
        WebViewStore.shared.adoptIntoKeeper()
    }
    func applicationDidUnhide(_ n: Notification) {
        clog("APP didUnhide")
        WebViewStore.shared.restoreFromKeeper()
    }

    // Dock-icon click. The 2px keeper counts as a "visible window", which turns AppKit's default
    // reopen behavior (deminiaturize/unhide the main window) into a NO-OP — after minimizing, the
    // window looked permanently gone. Handle reopen ourselves and tell AppKit to stand down.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        clog("APP reopen (Dock click) — restoring main window manually")
        for w in NSApp.windows where w.isMiniaturized { w.deminiaturize(nil) }
        if let win = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            win.makeKeyAndOrderFront(nil)
        } else {
            // Window was closed (menu-bar mode) — reopen via the app itself so SwiftUI recreates it.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
        WebViewStore.shared.restoreFromKeeper()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // When the menu-bar icon is shown, keep running there after the window closes (so the
        // status icon + global hotkey stay usable). Otherwise quit on last window close.
        !(UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Backstop: persist each panel's current conversation URL so we can reopen it next launch.
        WebViewStore.shared.saveAllSessionURLs()
        VoteStore.shared.commitPending()   // flush the current round's pick before quitting
    }

    // MARK: - Menu bar

    private var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    private func syncMenuBarVisibility() {
        if showMenuBarIcon {
            if statusItem == nil { setupStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: L("menubar.idle"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)                                   // index 0 — refreshed on open
        menu.addItem(.separator())
        menu.addItem(action(L("menu.newChat"), #selector(mbNewChatAll)))
        menu.addItem(action(L("menu.reloadAll"), #selector(mbReloadAll)))
        menu.addItem(.separator())
        menu.addItem(action(L("menubar.open"), #selector(mbOpenMain)))
        menu.addItem(action(L("menu.settings"), #selector(mbOpenSettings)))
        menu.addItem(.separator())
        menu.addItem(action(L("menu.checkUpdates"), #selector(mbCheckUpdates)))
        menu.addItem(action(L("menubar.quit"), #selector(mbQuit)))

        // Left-click summons the quick input (the valuable, discoverable path); right-click
        // (or control-click) shows this menu of occasional actions. We therefore DON'T assign
        // item.menu permanently — that would make left-click open the menu instead.
        statusMenu = menu
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateStatusIcon()
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick, let menu = statusMenu, let button = statusItem?.button {
            // Temporarily attach the menu so the button pops it, then detach so left-click
            // stays an action (the standard AppKit trick for left-action + right-menu).
            statusItem?.menu = menu
            button.performClick(nil)
            statusItem?.menu = nil
        } else {
            QuickInputWindowController.shared.toggle()
        }
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    private func updateStatusIcon() {
        // The brand glyph (app-icon circle character). Busy state is conveyed by the menu's status
        // line + the in-app streaming dots, so the menu-bar mark stays constant and recognizable.
        let img = ChorusGlyph.circle(size: 18, filled: true)
        img.accessibilityDescription = "Chorus"
        statusItem?.button?.image = img
    }

    // Refresh the dynamic status line each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let n = WebViewStore.shared.streamingKeys.count
        menu.items.first?.title = n == 0 ? L("menubar.idle") : Lf("menubar.thinking", n)
    }

    private func visibleKeys() -> [String] {
        let hidden = Set((UserDefaults.standard.string(forKey: "hiddenProviders") ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty })
        let all = ProviderRegistry.builtIn + ProviderRegistry.decode(UserDefaults.standard.string(forKey: "customProviders") ?? "")
        return all.map(\.key).filter { !hidden.contains($0) }
    }

    @objc private func mbNewChatAll() { visibleKeys().forEach { WebViewStore.shared.newChat(key: $0) } }
    @objc private func mbReloadAll()  { visibleKeys().forEach { WebViewStore.shared.reload(key: $0) } }

    @objc private func mbOpenMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            win.makeKeyAndOrderFront(nil)
        } else {
            // Window was closed (app still alive in the menu bar) — reopen via the app itself.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    @objc private func mbOpenSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func mbCheckUpdates() { UpdateManager.shared.checkForUpdates() }

    @objc private func mbQuit() { NSApp.terminate(nil) }
}

@main
struct ChorusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = WebViewStore.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1200, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("menu.checkUpdates")) { UpdateManager.shared.checkForUpdates() }
            }
            // ⌘H: a REAL app-hide (NSApp.hide) suspends WebKit at the APPLICATION level — pages
            // freeze even inside the canHide=false keeper window (watchdog logged Δ0 for the whole
            // hidden stretch), so completions/notifications stalled until unhide. Minimizing goes
            // through the window-level path the keeper provably survives, and looks the same to
            // the user. (Dock-menu Hide still performs a real hide — rare path, keeper adopts as
            // a best effort there.)
            CommandGroup(replacing: .appVisibility) {
                Button(L("menu.hide")) {
                    for w in NSApp.windows where w.canBecomeMain && !(w is NSPanel) {
                        w.miniaturize(nil)
                    }
                }
                .keyboardShortcut("h", modifiers: .command)
                Button(L("menu.hideOthers")) { NSApp.hideOtherApplications(nil) }
                    .keyboardShortcut("h", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
