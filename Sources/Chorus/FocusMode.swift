import Foundation

/// Focus mode: each panel shows just the conversation. The site's own top bar, sidebar, input
/// box and "AI can make mistakes" line are hidden — the pane header and Chorus's composer already do
/// those jobs, and four input boxes on one screen read as four web pages rather than one app.
///
/// Cosmetic CSS only, like the warm tint: nothing is clicked or sent, and the server sees the
/// same page. The hidden input box stays in the page at its full size — transparent and
/// click-through, never display:none — because broadcasting types into it and completion
/// watches the stop button inside it, and both first check that the element is really rendered
/// (`onScreen` / `isReallyVisible` in the broadcast script).
///
/// Rules exist per site; a site without rules is left as it is, and a redesign that breaks a
/// selector only brings that piece of the site's UI back. Top bars stay while the page offers a
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
    // every release). Checked against the live pages on 2026-09-26.
    static let rules: [(host: String, css: String)] = [
        ("chatgpt.com", """
        body:not(:has([data-testid="login-button"])) header[data-app-shell-titlebar],
        body:not(:has([data-testid="login-button"])) aside[data-app-shell-left-panel-appearance],
        body:not(:has([data-testid="login-button"])) nav[data-app-navigation-rail] { display: none !important; }
        body:not(:has([data-testid="login-button"])) [data-app-shell-thread-edge-divider] { margin-top: 0 !important; }
        body:not(:has([data-testid="login-button"])) main[data-app-shell-main-surface] { border-left-width: 0 !important; }
        form[data-chatgpt-composer] { opacity: 0 !important; }
        form[data-chatgpt-composer], form[data-chatgpt-composer] * { pointer-events: none !important; }
        [data-markdown-copy="exclude"].text-center.text-xs { display: none !important; }
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
        ("chat.deepseek.com", """
        div:has(> .the-header),
        div:has(> div > div > .ds-virtual-list) > div:not(:has(.ds-virtual-list)) { display: none !important; }
        .ds-virtual-list > div:not(.ds-virtual-list-items):has(textarea) { opacity: 0 !important; }
        .ds-virtual-list > div:not(.ds-virtual-list-items):has(textarea),
        .ds-virtual-list > div:not(.ds-virtual-list-items):has(textarea) * { pointer-events: none !important; }
        div:has(> div > div > div > textarea) { opacity: 0 !important; }
        div:has(> div > div > div > textarea), div:has(> div > div > div > textarea) * { pointer-events: none !important; }
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
