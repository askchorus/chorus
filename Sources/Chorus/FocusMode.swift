import Foundation

/// Focus mode: each panel shows just the conversation. The site's own top bar, sidebar, input
/// box and "AI can make mistakes" line are hidden — the pane header and Chorus's composer already do
/// those jobs, and four input boxes on one screen read as four web pages rather than one app.
///
/// Cosmetic CSS only, like the warm tint: nothing is clicked or sent, and the server sees the
/// same page. The hidden input box stays in the page at its full size — transparent and
/// click-through, never display:none — because broadcasting types into it and completion
/// watches the stop button inside it, and both first check that the element is really rendered
/// (`onScreen` / `isReallyVisible` in the broadcast script). What each site RESERVES for it — a
/// sticky block or a spacer at the end of the conversation — is collapsed, so answers run to
/// the bottom of the pane instead of stopping above a blank band. Never by clipping a box the
/// script types into: WebKit reports clipped text as empty (innerText), so an editor inside an
/// overflow:hidden, zero-height block looks empty and the send never happens — such a block is
/// taken out of the flow instead (position:absolute).
///
/// Only the box goes, not the notices a site shows beside it — Claude's "You've used 75% of your
/// weekly limit", ChatGPT's limit banners. Those stay, at the bottom of the pane, and the site's
/// own measurement of what sits there keeps the conversation clear of them.
///
/// Rules exist per site; a site without rules is left as it is, and a redesign that breaks a
/// selector only brings that piece of the site's UI back. Input boxes inside the conversation
/// (editing a sent message) are never hidden — only the one at the bottom. Top bars stay while the page offers a
/// sign-in link — that's where it lives. A panel can opt out from its "…" menu when the user
/// needs a site's own switches (model picker, DeepThink…).
enum FocusMode {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "focusMode") as? Bool ?? true }

    /// Panels showing the site's own controls even though focus mode is on.
    static var siteControlPanels: Set<String> {
        Set((UserDefaults.standard.string(forKey: "focusSiteControlPanels") ?? "")
            .split(separator: ",").map(String.init))
    }

    static func isOn(forPanel key: String) -> Bool { enabled && !siteControlPanels.contains(key) }

    static func setSiteControls(_ shown: Bool, forPanel key: String) {
        var keys = siteControlPanels
        if shown { keys.insert(key) } else { keys.remove(key) }
        UserDefaults.standard.set(keys.sorted().joined(separator: ","), forKey: "focusSiteControlPanels")
    }

    /// Whether focus mode has anything to hide on this site.
    static func supports(host: String) -> Bool {
        rules.contains { host == $0.host || host.hasSuffix("." + $0.host) }
    }

    // Selectors lean on what survives a site's redeploys — data attributes, custom-element tags,
    // design-system class names — never hashed class names (DeepSeek re-hashes its classes on
    // every release). Checked against the live pages on 2026-09-27.
    static let rules: [(host: String, css: String)] = [
        // ChatGPT keeps the thread clear of its bottom bar by measuring that bar and writing the
        // height into --thread-scroll-padding-bottom. With the input card lifted out and the bar's
        // padding gone, the bar holds only its notices slot, so the measurement comes to the
        // notice's height — or nothing — plus ChatGPT's own 16px.
        ("chatgpt.com", """
        body:not(:has([data-testid="login-button"])) header[data-app-shell-titlebar],
        body:not(:has([data-testid="login-button"])) aside[data-app-shell-left-panel-appearance],
        body:not(:has([data-testid="login-button"])) nav[data-app-navigation-rail] { display: none !important; }
        body:not(:has([data-testid="login-button"])) [data-app-shell-thread-edge-divider] { margin-top: 0 !important; }
        body:not(:has([data-testid="login-button"])) main[data-app-shell-main-surface] { border-left-width: 0 !important; }
        form[data-chatgpt-composer]:not([data-content-search-unit-key] *) > :has([contenteditable="true"], textarea) { opacity: 0 !important; }
        form[data-chatgpt-composer]:not([data-content-search-unit-key] *) > :has([contenteditable="true"], textarea),
        form[data-chatgpt-composer]:not([data-content-search-unit-key] *) > :has([contenteditable="true"], textarea) * { pointer-events: none !important; }
        [data-thread-scroll-footer] form[data-chatgpt-composer] > :has([contenteditable="true"], textarea) {
          position: absolute !important; left: 0 !important; right: 0 !important; bottom: 0 !important; }
        [data-thread-scroll-footer]:has(form[data-chatgpt-composer]) { padding-bottom: 0 !important; }
        [data-markdown-copy="exclude"].text-center.text-xs { display: none !important; }
        """),
        // claude.ai's markup is semantic (data-testid / data-cds / data-disclaimer). Its chat page
        // floats the title bar over a 48px padding; the new-chat page stacks a <header> instead.
        // The input box is the card around the editor, plus the page-coloured backdrop it sits on;
        // Claude's notices live in the same fieldset, just above it, and stay. A fieldset without
        // that card (a redesign) is hidden whole, as before.
        ("claude.ai", """
        [data-testid="chat-header"]:not(:has([data-testid="user-message"], .font-claude-response)),
        header.dframe-header:not(:has([data-testid="user-message"], .font-claude-response)),
        aside.dframe-sidebar:not(:has([data-testid="user-message"], .font-claude-response)) { display: none !important; }
        div:has(> [data-testid="chat-header"]) { padding-top: 0 !important; }
        div:has(> [data-tap-focuses-field] [data-testid="chat-input"]) { opacity: 0 !important; }
        div:has(> [data-tap-focuses-field] [data-testid="chat-input"]),
        div:has(> [data-tap-focuses-field] [data-testid="chat-input"]) * { pointer-events: none !important; }
        fieldset:has([data-testid="chat-input"]):not(:has([data-tap-focuses-field], [data-testid="user-message"], .font-claude-response)) { opacity: 0 !important; }
        fieldset:has([data-testid="chat-input"]):not(:has([data-tap-focuses-field], [data-testid="user-message"], .font-claude-response)),
        fieldset:has([data-testid="chat-input"]):not(:has([data-tap-focuses-field], [data-testid="user-message"], .font-claude-response)) * { pointer-events: none !important; }
        [data-disclaimer="true"] { display: none !important; }
        [data-chat-input-container]:not(:has([data-testid="user-message"], .font-claude-response)) { padding-top: 0 !important; }
        [data-chat-input-container] div:has(> [data-tap-focuses-field] [data-testid="chat-input"]) {
          position: absolute !important; left: 0 !important; right: 0 !important; bottom: 0 !important; }
        [data-testid="last-message-sentinel"] ~ div.h-12:not([data-testid]) { height: 1rem !important; }
        [data-testid="transcript-bottom-fade"] { display: none !important; }
        """),
        ("gemini.google.com", """
        body:not(:has(a[href*="ServiceLogin"])) > .boqOnegoogleliteOgbOneGoogleBar,
        body:not(:has(a[href*="ServiceLogin"])) div.side-nav-menu-button,
        body:not(:has(a[href*="ServiceLogin"])) top-bar-actions,
        body:not(:has(a[href*="ServiceLogin"])) bard-sidenav { display: none !important; }
        body:not(:has(a[href*="ServiceLogin"])) chat-app { padding-top: 0 !important; }
        input-container { position: absolute !important; left: 0 !important; right: 0 !important; bottom: 0 !important;
                          background: none !important; pointer-events: none !important; }
        input-container::before { display: none !important; }
        input-container .input-area-container { opacity: 0 !important; }
        input-container .input-area-container, input-container .input-area-container * { pointer-events: none !important; }
        input-container back-to-bottom-fab { pointer-events: auto !important; }
        hallucination-disclaimer, condensed-tos-disclaimer { display: none !important; }
        """),
        // DeepSeek's are structural (no stable names to go on), so each also refuses to hide a
        // block holding the conversation: if the page reshapes, a rule lets go instead of
        // blanking the pane. (A rule for its wide-layout sidebar did exactly that once — a search
        // panel matched it and the whole conversation vanished — and was dropped.)
        ("chat.deepseek.com", """
        div:has(> .the-header):not(:has(.ds-markdown, .ds-virtual-list, textarea)) { display: none !important; }
        .ds-virtual-list > div:not(.ds-virtual-list-items):has(textarea):not(:has(.ds-markdown)) {
          opacity: 0 !important; height: 0 !important; min-height: 0 !important; overflow: hidden !important; }
        .ds-virtual-list > div:not(.ds-virtual-list-items):has(textarea):not(:has(.ds-markdown)),
        .ds-virtual-list > div:not(.ds-virtual-list-items):has(textarea):not(:has(.ds-markdown)) * { pointer-events: none !important; }
        div:has(> div > div > div > textarea):not(:has(.ds-markdown, .ds-message, .ds-virtual-list)):not(.ds-virtual-list-items *) { opacity: 0 !important; }
        div:has(> div > div > div > textarea):not(:has(.ds-markdown, .ds-message, .ds-virtual-list)):not(.ds-virtual-list-items *),
        div:has(> div > div > div > textarea):not(:has(.ds-markdown, .ds-message, .ds-virtual-list)):not(.ds-virtual-list-items *) * { pointer-events: none !important; }
        """),
    ]

    /// Adds this site's stylesheet (a no-op on sites without rules). Re-adds it if a framework
    /// re-renders <head> — the observer watches head's direct children only, so it costs nothing
    /// while an answer streams.
    static var addJS: String {
        let map = Dictionary(uniqueKeysWithValues: rules.map { ($0.host, $0.css) })
        let json = (try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function(){
          var RULES=\(json), h=location.hostname, css=null;
          for (var k in RULES) if (h===k || h.endsWith('.'+k)) { css=RULES[k]; break; }
          if (!css) return;
          var ID='chorus-focus';
          function add(){
            if (document.getElementById(ID)) return;
            var s=document.createElement('style'); s.id=ID; s.textContent=css;
            (document.head||document.documentElement).appendChild(s);
          }
          add();
          if (!window.__chorusFocusObs && document.head) {
            window.__chorusFocusObs=new MutationObserver(function(){ if(!document.getElementById(ID)) add(); });
            window.__chorusFocusObs.observe(document.head,{childList:true});
          }
        })();
        """
    }

    static let removeJS = """
    (function(){
      var s=document.getElementById('chorus-focus'); if(s) s.remove();
      if(window.__chorusFocusObs){ window.__chorusFocusObs.disconnect(); window.__chorusFocusObs=null; }
    })();
    """
}
