import SwiftUI
import WebKit

/// Wraps a persistent WKWebView in a container NSView. The WKWebView itself is owned by
/// `WebViewStore`, not by this view — so when SwiftUI re-renders (e.g. after reordering),
/// the same WKWebView is just reparented to the new container instead of being recreated.
/// This preserves navigation state, scroll, in-flight messages, etc.
struct WebPanel: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        embed(webView, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container {
            embed(webView, in: container)
        }
    }

    private func embed(_ webView: WKWebView, in container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

/// Intercepts link clicks in the embedded AI panels and routes external links
/// to Chrome (or the user's default browser if Chrome isn't installed). Keeps
/// same-host navigation in the webview so internal flows like "switch conversation"
/// or "click on a prior message" stay where you'd expect.
@MainActor
final class LinkRoutingDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = LinkRoutingDelegate()
    private override init() { super.init() }

    /// When set, the next file-open panel (triggered by a web page's <input type=file>)
    /// is auto-answered with this URL instead of showing a dialog. This is how we feed
    /// an image into Gemini, which renders no static file input and ignores synthetic
    /// paste/drop. The broadcaster writes the image to a temp file, sets this, then drives
    /// Gemini's "Upload files" menu — WebKit calls runOpenPanel, we supply the file silently.
    /// Single-shot: cleared as soon as it's consumed.
    var pendingUpload: URL?

    // Plain link clicks (anchor tags, no target=_blank).
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let linkHost = url.host ?? ""
        let currentHost = webView.url?.host ?? ""

        // Same-host clicks (e.g. switching ChatGPT conversations, Claude sidebar
        // entries) — keep them inside the panel.
        if isSameSite(linkHost, currentHost) {
            decisionHandler(.allow)
            return
        }

        // External link → punt to Chrome
        Task { @MainActor in Self.openExternally(url) }
        decisionHandler(.cancel)
    }

    // target=_blank and window.open() — never open these inside the panel.
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            Task { @MainActor in Self.openExternally(url) }
        }
        return nil
    }

    // File upload panel. Web page triggered an <input type=file>. If we have a pending
    // programmatic upload (Gemini image), answer with it silently — no dialog. Otherwise
    // show the real NSOpenPanel so manual uploads inside the panels still work normally.
    nonisolated func webView(_ webView: WKWebView,
                             runOpenPanelWith parameters: WKOpenPanelParameters,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping ([URL]?) -> Void) {
        Task { @MainActor in
            // Only auto-answer for Gemini. Host-scoping prevents a manual file pick in another
            // panel (or a stray panel) from consuming the armed image during its brief window.
            let host = webView.url?.host ?? ""
            let isGemini = host.contains("gemini.google.com") || host.contains("gemini")
            if let pending = self.pendingUpload, isGemini {
                self.pendingUpload = nil  // single-shot
                chorusLog.notice("[Chorus.OpenPanel] FIRED on \(host, privacy: .public) — auto-supplying \(pending.lastPathComponent, privacy: .public) (no dialog)")
                completionHandler([pending])
            } else {
                // Either no pending upload, or a non-Gemini panel — show the real dialog and
                // leave any armed Gemini upload intact for when Gemini's own panel fires.
                chorusLog.notice("[Chorus.OpenPanel] FIRED on \(host, privacy: .public) — showing NSOpenPanel (pending=\(self.pendingUpload != nil))")
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = parameters.allowsMultipleSelection
                panel.begin { resp in
                    completionHandler(resp == .OK ? panel.urls : nil)
                }
            }
        }
    }

    /// Hand the URL to the system's default browser (which the user sets in
    /// System Settings → Desktop & Dock → Default web browser). Same fallback
    /// handles mailto:, tel:, etc. — macOS routes to the right app.
    static func openExternally(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Treat related hosts as the same site so internal nav (`accounts.google.com` ↔
    /// `gemini.google.com`) doesn't bounce out. Strict eTLD+1 would need a public-suffix
    /// list; for our three AIs the "same registered domain" heuristic is enough.
    nonisolated private func isSameSite(_ a: String, _ b: String) -> Bool {
        func base(_ h: String) -> String {
            var h = h
            if h.hasPrefix("www.") { h.removeFirst(4) }
            let parts = h.split(separator: ".")
            // last two labels: e.g. "google.com", "openai.com"
            return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : h
        }
        if a.isEmpty || b.isEmpty { return false }
        return base(a) == base(b)
    }
}

/// Receives diagnostic logs from the broadcast JS and forwards them to macOS
/// unified logging. Lets us debug per-site upload issues without making the
/// user open Web Inspector. Read back with:
///   log show --subsystem com.smiletalker.chorus --info --debug --last 5m
@MainActor
final class JSLogHandler: NSObject, WKScriptMessageHandler {
    static let shared = JSLogHandler()
    private override init() { super.init() }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        chorusLog.notice("[Chorus.JS] \(s, privacy: .public)")
    }
}

/// Bridges JS `webkit.messageHandlers.chorusCompletion.postMessage({host})`
/// back to Swift. Singleton — same handler instance is attached to every WKWebView.
@MainActor
final class CompletionScriptHandler: NSObject, WKScriptMessageHandler {
    static let shared = CompletionScriptHandler()

    /// Called on main actor with the page hostname (e.g. "chatgpt.com").
    var onCompletion: ((String) -> Void)?
    /// Called on main actor when a host's streaming state changes (true = started,
    /// false = timed out). Used to drive the per-panel "thinking" status dot.
    var onStreamingState: ((String, Bool) -> Void)?

    private override init() { super.init() }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let host = body["host"] as? String else { return }
        // Diagnostic-only messages: log but don't count as completion.
        if let diag = body["diagnostic"] as? String {
            chorusLog.notice("[Chorus.Poll] \(host, privacy: .public) — \(diag, privacy: .public)")
            if diag == "streaming-started" {
                Task { @MainActor in self.onStreamingState?(host, true) }
            } else if diag == "timeout-no-completion" {
                Task { @MainActor in self.onStreamingState?(host, false) }
            }
            return
        }
        Task { @MainActor in
            self.onCompletion?(host)
        }
    }
}

/// Builds and caches WKWebViews. Used by `WebViewStore` to keep webview instances
/// alive across SwiftUI view rebuilds.
enum WebViewFactory {
    // Standard Safari macOS UA — used by ChatGPT and Claude.
    private static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    // Chrome macOS UA — used for Google services. Google's serving tier historically
    // ships a heavier / legacy JS bundle to non-Chrome UAs (Polymer/Shadow-DOM-v0
    // incident in 2018, ongoing through Gemini era). UA-Client-Hints sometimes
    // sees through this, but a Chrome UA still has ~30-40% chance of unlocking
    // the optimized code path.
    private static let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    @MainActor
    static func make(url: URL) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent: cookies/login survive app restart
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Public API (macOS 14+): keep the page scheduler running even when the webview
        // is "inactive". Doesn't address occlusion-based throttling by itself, but it
        // closes the "view detached from hierarchy" suspension path. Defensive setting.
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }

        // Install completion-detection bridge: JS will postMessage to "chorusCompletion"
        // when a streamed response finishes (send button transitions disabled → enabled).
        config.userContentController.add(CompletionScriptHandler.shared, name: "chorusCompletion")
        // Install diagnostic log bridge so JS `[Chorus]` logs reach unified logging.
        config.userContentController.add(JSLogHandler.shared, name: "chorusJSLog")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // Route link clicks: same-site stays in panel, external links → Chrome.
        webView.navigationDelegate = LinkRoutingDelegate.shared
        webView.uiDelegate = LinkRoutingDelegate.shared

        // CRITICAL FIX for background streaming: disable WebKit's "window is occluded →
        // throttle WebContent process" pipeline. This is the same private SPI that
        // WebKitTestRunner uses (WebKit bug 111116) so layout tests aren't disturbed
        // by window visibility. Without this, the user's "send from another app and
        // get notified" workflow doesn't work — pages freeze when our window is hidden.
        // Private API; raises no warning at compile time; only safe outside Mac App Store.
        disableWindowOcclusionDetection(webView)

        let host = url.host ?? ""
        let isGoogleService = host.contains("google.com") || host.contains("gemini")
        webView.customUserAgent = isGoogleService ? chromeUA : safariUA

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        webView.load(URLRequest(url: url))
        return webView
    }

    /// Invokes the private SPI `-[WKWebView _setWindowOcclusionDetectionEnabled:]`
    /// via the Objective-C runtime. No-ops gracefully if Apple ever removes the SPI.
    private static func disableWindowOcclusionDetection(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else {
            chorusLog.notice("[Chorus.WebKit] _setWindowOcclusionDetectionEnabled: not available — page will throttle in background")
            return
        }
        typealias SetterIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let imp = webView.method(for: selector)
        let setter = unsafeBitCast(imp, to: SetterIMP.self)
        setter(webView, selector, ObjCBool(false))
        chorusLog.notice("[Chorus.WebKit] disabled window occlusion detection for \(webView.url?.host ?? "<unknown>", privacy: .public)")
    }
}

enum Broadcaster {
    /// Builds the JS payload that injects text and (optionally) an image into the AI site,
    /// then clicks send once the send button becomes enabled.
    /// - Parameters:
    ///   - text: prompt text (may be empty if image-only)
    ///   - imageBase64: base64-encoded PNG bytes, or nil
    ///   - imageMime: MIME type of the image, defaults to "image/png"
    ///   - waitForGeminiUpload: when true, the script attaches NO image itself but first waits
    ///     for an externally-supplied image (Gemini's runOpenPanel upload) to finish appearing
    ///     in the composer before typing + sending. Avoids firing send on a half-uploaded image.
    static func injectionScript(text: String, imageBase64: String? = nil, imageMime: String = "image/png", waitForGeminiUpload: Bool = false) -> String {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        let imageJS = imageBase64.map { "\"\($0)\"" } ?? "null"
        let mimeJS = "\"\(imageMime)\""
        let waitUploadJS = waitForGeminiUpload ? "true" : "false"

        return """
        (async () => {
          const TEXT = "\(escapedText)";
          const IMAGE_B64 = \(imageJS);
          const IMAGE_MIME = \(mimeJS);
          const WAIT_UPLOAD = \(waitUploadJS);

          // Diagnostic log → Swift (visible in `log show --subsystem com.smiletalker.chorus`).
          const clog = (msg) => {
            try {
              window.webkit?.messageHandlers?.chorusJSLog?.postMessage(
                location.hostname + ': ' + msg
              );
            } catch (_) {}
            try { console.log('[Chorus]', msg); } catch (_) {}
          };

          const HOSTS = [
            {
              host: 'chatgpt.com',
              inputSelectors: ['#prompt-textarea', 'main div[contenteditable="true"]'],
              sendSelectors: [
                'button[data-testid="send-button"]',
                'button[data-testid="composer-send-button"]',
                'button[aria-label*="Send" i]'
              ],
              uploadMethod: 'paste',
              fileInputSelectors: [
                'input[type="file"][multiple][accept]',
                'input[type="file"][accept*="image"]',
                'input[type="file"]'
              ],
            },
            {
              host: 'claude.ai',
              inputSelectors: [
                'div[contenteditable="true"].ProseMirror',
                'fieldset div[contenteditable="true"]',
                'div[contenteditable="true"]'
              ],
              sendSelectors: [
                'button[aria-label="Send Message"]',
                'button[aria-label="Send message"]',
                'button[aria-label*="Send" i]'
              ],
              uploadMethod: 'paste',
              fileInputSelectors: [
                'input[type="file"][accept*="image"]',
                'input[data-testid*="file"]',
                'input[type="file"]'
              ],
            },
            {
              host: 'gemini.google.com',
              inputSelectors: [
                'rich-textarea div.ql-editor[contenteditable="true"]',
                'div.ql-editor[contenteditable="true"]',
                'div[contenteditable="true"]'
              ],
              sendSelectors: [
                'button[aria-label*="Send message" i]',
                'button.send-button',
                'button[aria-label*="Send" i]'
              ],
              // Gemini doesn't render a static file input — it lazily creates one
              // after clicking "Upload & tools". Use clickUpload strategy.
              uploadMethod: 'clickUpload',
              uploadButtonSelectors: [
                'button[aria-label="Upload & tools"]',
                'button[aria-label*="Upload" i]',
                'button[aria-label*="Add files" i]',
                'button[mattooltip*="Upload" i]',
              ],
              dropTargetSelectors: [
                'rich-textarea',
                'div.ql-editor[contenteditable="true"]',
                'div[contenteditable="true"]'
              ],
              fileInputSelectors: [
                'input[type="file"][accept*="image"]',
                'input[type="file"][multiple]',
                'input[type="file"]'
              ],
            },
          ];

          let cfg = HOSTS.find(c =>
            location.hostname === c.host || location.hostname.endsWith('.' + c.host)
          );
          if (!cfg) {
            // User-added provider — no tuned selectors. Most chat AIs use a contenteditable
            // or textarea plus a Send button (or Enter), so a broad set usually works for text.
            // Image upload isn't guaranteed for these (best-effort paste only).
            cfg = {
              host: location.hostname,
              inputSelectors: ['div[contenteditable="true"]', 'textarea', 'input[type="text"]'],
              sendSelectors: [
                'button[aria-label*="Send" i]',
                'button[data-testid*="send" i]',
                'button[class*="send" i]',
                'button[type="submit"]',
              ],
              uploadMethod: 'paste',
              fileInputSelectors: ['input[type="file"][accept*="image"]', 'input[type="file"]'],
            };
            clog('using generic config for ' + location.hostname);
          }

          const pickFirst = (selectors) => {
            for (const sel of selectors) {
              const el = document.querySelector(sel);
              if (el && el.offsetParent !== null) return el;
            }
            for (const sel of selectors) {
              const el = document.querySelector(sel);
              if (el) return el;
            }
            return null;
          };

          const pickAll = (selectors) => {
            const results = [];
            for (const sel of selectors) {
              document.querySelectorAll(sel).forEach(el => results.push(el));
            }
            return [...new Set(results)];
          };

          // Like pickAll but walks every shadow root too — required for Polymer/Lit
          // sites like Gemini where the composer's file input lives inside a Web
          // Component's shadowRoot that a flat document.querySelectorAll can't reach.
          const deepQueryAll = (selectors) => {
            const results = [];
            const stack = [document];
            while (stack.length) {
              const root = stack.pop();
              if (!root) continue;
              for (const sel of selectors) {
                try {
                  const found = root.querySelectorAll?.(sel);
                  if (found) for (const el of found) results.push(el);
                } catch (_) {}
              }
              const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
              for (const el of all) {
                if (el.shadowRoot) stack.push(el.shadowRoot);
              }
            }
            return [...new Set(results)];
          };

          const input = pickFirst(cfg.inputSelectors);
          if (!input && (TEXT || IMAGE_B64)) return 'input not found';

          // 1) Attach image FIRST (if any)
          // Reason: some composers (Claude) clear the input on paste-with-file.
          // Doing image first means the file attaches to a separate attachment slot,
          // and text inserted afterwards lands cleanly in the empty editor.
          let imageAttached = false;
          if (IMAGE_B64) {
            // Decode base64 → File
            const byteString = atob(IMAGE_B64);
            const bytes = new Uint8Array(byteString.length);
            for (let i = 0; i < byteString.length; i++) bytes[i] = byteString.charCodeAt(i);
            const ext = IMAGE_MIME.split('/')[1] || 'png';
            const file = new File([new Blob([bytes], { type: IMAGE_MIME })], `pasted.${ext}`, { type: IMAGE_MIME });

            const method = cfg.uploadMethod || 'paste';

            // Diagnostic DOM scan — runs BEFORE any strategy. Helps debug "why doesn't
            // Gemini upload" by showing what file inputs / upload buttons actually exist.
            const scanForUploadTargets = () => {
              const fileInputs = deepQueryAll(['input[type="file"]']);
              const uploadButtons = deepQueryAll([
                'button[aria-label*="upload" i]',
                'button[aria-label*="attach" i]',
                'button[aria-label*="add" i]',
                'button[mattooltip*="upload" i]',
                'button[mattooltip*="attach" i]',
              ]);
              clog('image-upload scan: method=' + method + ' fileInputs=' + fileInputs.length + ' uploadButtons=' + uploadButtons.length);
              fileInputs.slice(0, 3).forEach((fi, i) => {
                clog('  fileInput[' + i + ']: accept=' + (fi.accept || '?') + ' multiple=' + (fi.multiple || false) + ' name=' + (fi.name || '?'));
              });
              uploadButtons.slice(0, 3).forEach((b, i) => {
                clog('  uploadBtn[' + i + ']: label=' + (b.getAttribute('aria-label') || b.getAttribute('mattooltip') || '?'));
              });
            };

            // Define deepQueryAll early since scanForUploadTargets uses it
            // (the existing const declaration further down still works because of hoisting in arrow-fn context, but we just call it after the const below)

            const tryPaste = () => {
              if (!input) return false;
              try {
                const dt = new DataTransfer();
                dt.items.add(file);
                const pasteEvent = new ClipboardEvent('paste', {
                  clipboardData: dt,
                  bubbles: true,
                  cancelable: true,
                });
                input.focus();
                input.dispatchEvent(pasteEvent);
                return true;
              } catch (e) {
                console.warn('paste event failed', e);
                return false;
              }
            };

            const tryDrop = () => {
              const targets = (cfg.dropTargetSelectors || cfg.inputSelectors)
                .flatMap(sel => Array.from(document.querySelectorAll(sel)))
                .filter(Boolean);
              if (targets.length === 0) return false;
              for (const target of targets) {
                try {
                  const dt = new DataTransfer();
                  dt.items.add(file);
                  ['dragenter', 'dragover', 'drop'].forEach(type => {
                    target.dispatchEvent(new DragEvent(type, {
                      dataTransfer: dt,
                      bubbles: true,
                      cancelable: true,
                    }));
                  });
                  return true;
                } catch (e) { /* try next target */ }
              }
              return false;
            };

            const tryFileInput = () => {
              const fileInputs = deepQueryAll(cfg.fileInputSelectors || ['input[type="file"]']);
              clog('tryFileInput: deep-found ' + fileInputs.length + ' file inputs');
              if (fileInputs.length === 0) return false;
              for (const fi of fileInputs) {
                try {
                  const dt = new DataTransfer();
                  dt.items.add(file);
                  fi.files = dt.files;
                  fi.dispatchEvent(new Event('change', { bubbles: true }));
                  clog('tryFileInput: set files on ' + (fi.outerHTML || '?').slice(0, 120));
                  return true;
                } catch (e) {
                  clog('tryFileInput: setting files threw — ' + e);
                }
              }
              return false;
            };

            // Gemini-style "lazy" upload: site doesn't render a file input until
            // you click its "Upload & tools" button. Click it, wait for the DOM
            // to spin up an <input type="file">, and (if a menu pops instead)
            // click the matching menu item, then set files on the input.
            const tryClickThenFileInput = async () => {
              const buttons = deepQueryAll(cfg.uploadButtonSelectors || []);
              clog('clickThenFileInput: found ' + buttons.length + ' upload buttons');
              if (buttons.length === 0) return false;

              const btn = buttons[0];
              const btnLabel = (btn.getAttribute('aria-label') || '').toLowerCase().trim();
              clog('clickThenFileInput: clicking "' + btnLabel + '"');

              // Material Design buttons frequently listen to pointer events but
              // ignore raw .click() — dispatch the full pointer/mouse sequence.
              const fireFullClick = (el) => {
                const rect = el.getBoundingClientRect();
                const opts = {
                  bubbles: true, cancelable: true,
                  clientX: rect.left + rect.width / 2,
                  clientY: rect.top + rect.height / 2,
                  button: 0, view: window,
                };
                try { el.dispatchEvent(new PointerEvent('pointerdown', opts)); } catch (_) {}
                el.dispatchEvent(new MouseEvent('mousedown', opts));
                try { el.dispatchEvent(new PointerEvent('pointerup', opts)); } catch (_) {}
                el.dispatchEvent(new MouseEvent('mouseup', opts));
                try { el.click(); } catch (_) {}
              };
              clog('clickThenFileInput: btn=' + (btn.outerHTML || '').slice(0, 140));
              fireFullClick(btn);
              await new Promise(r => setTimeout(r, 700));

              let inputs = deepQueryAll(['input[type="file"]']);
              clog('clickThenFileInput: after click, ' + inputs.length + ' file inputs');

              // If the click didn't directly reveal an input, the trigger probably
              // opened a menu/popup. Dump EVERYTHING the click revealed so we can see
              // Gemini's real markup (it changes often). Then click the best match.
              if (inputs.length === 0) {
                // Did anything menu-like appear at all? (distinguishes "click did
                // nothing" from "menu opened but no matching item").
                const roleEls = deepQueryAll([
                  '[role="menuitem"]', '[role="option"]', '[role="menu"]',
                  '[role="dialog"]', '[role="listbox"]',
                ]);
                const overlayEls = deepQueryAll([
                  '.cdk-overlay-container', '.cdk-overlay-pane', '.mat-mdc-menu-panel',
                ]);
                clog('clickThenFileInput: post-click roleEls=' + roleEls.length +
                     ' overlayEls=' + overlayEls.length);

                // All upload-hinting clickables (light DOM + shadow + CDK overlay).
                const hints = deepQueryAll([
                  'button', 'a', '[role="button"]', '[role="menuitem"]',
                  '[role="option"]', '[mat-menu-item]', 'div[tabindex]',
                ]).filter(el => {
                  if (el === btn) return false;
                  const t = ((el.textContent || '') + ' ' +
                             (el.getAttribute('aria-label') || '')).toLowerCase().trim();
                  if (!t || t === btnLabel || t.includes('upload & tools')) return false;
                  return /upload|from computer|add file|files from|photo|gallery|相册|拍照|从电脑|上传文件|本地文件|图片|文件/.test(t);
                });
                clog('clickThenFileInput: ' + hints.length + ' upload-hint clickables');
                hints.slice(0, 12).forEach((el, i) => {
                  const t = ((el.textContent || '') + ' | ' +
                             (el.getAttribute('aria-label') || '')).trim();
                  clog('  hint[' + i + ']: <' + el.tagName.toLowerCase() + '> "' +
                       t.slice(0, 70) + '"');
                });

                if (hints.length > 0) {
                  clog('clickThenFileInput: clicking hint[0]');
                  fireFullClick(hints[0]);
                  await new Promise(r => setTimeout(r, 700));
                }

                inputs = deepQueryAll(['input[type="file"]']);
                clog('clickThenFileInput: after hint click, ' + inputs.length + ' file inputs');
              }

              for (const fi of inputs) {
                try {
                  const dt = new DataTransfer();
                  dt.items.add(file);
                  fi.files = dt.files;
                  fi.dispatchEvent(new Event('change', { bubbles: true }));
                  clog('clickThenFileInput: set files on ' + (fi.outerHTML || '?').slice(0, 120));
                  return true;
                } catch (e) {
                  clog('clickThenFileInput: setting files threw — ' + e);
                }
              }
              return false;
            };

            // Diagnostic scan before running strategies
            scanForUploadTargets();

            // Run primary strategy; on failure walk through remaining methods.
            const order = method === 'drop'
              ? [['drop', tryDrop], ['fileInput', tryFileInput], ['paste', tryPaste]]
              : method === 'fileInput'
                ? [['fileInput', tryFileInput], ['paste', tryPaste], ['drop', tryDrop]]
                : method === 'clickUpload'
                  ? [['clickUpload', tryClickThenFileInput], ['fileInput', tryFileInput], ['paste', tryPaste], ['drop', tryDrop]]
                  : [['paste', tryPaste], ['fileInput', tryFileInput], ['drop', tryDrop]];

            // `await` is safe on sync returns (just resolves immediately) — keeps
            // the loop compatible with both sync and async strategy functions.
            for (const [name, fn] of order) {
              let ok = false;
              try { ok = await fn(); } catch (e) { clog(name + ' threw: ' + e); }
              clog('strategy ' + name + ' returned ' + ok);
              if (ok) { imageAttached = true; break; }
            }

            // Wait for the upload to register in the UI (composer shows attached file).
            // Bumped from 800ms to 1500ms because Claude's React state sometimes hadn't
            // committed the attachment yet at 800ms, causing send-before-image races.
            await new Promise(r => setTimeout(r, 1500));
          }

          // 1b) Gemini panel-upload path: the image is uploaded out-of-band (native
          //     runOpenPanel), so this script attaches nothing — but it MUST wait for the
          //     image to finish appearing in the composer before typing/sending, or Gemini
          //     sends a text-only message ("you forgot the image"). Poll for the uploaded
          //     thumbnail (blob:/data: img) or a remove-attachment affordance.
          if (WAIT_UPLOAD) {
            // Phase 1 — wait for the local preview thumbnail to appear (upload accepted).
            // NOTE: this shows INSTANTLY (a blob: preview) and does NOT mean the server-side
            // upload is done. It's only "the file was accepted into the composer".
            const thumb = () => deepQueryAll(['img[src^="blob:"]', 'img[src^="data:image"]'])
              .concat(deepQueryAll(['button[aria-label*="remove" i]', 'button[aria-label*="delete" i]',
                                    'button[aria-label*="移除" i]', 'button[aria-label*="删除" i]']));
            const t0 = Date.now();
            while (Date.now() - t0 < 20000) {
              if (thumb().length) break;
              await new Promise(r => setTimeout(r, 250));
            }
            clog('WAIT_UPLOAD: preview appeared=' + (thumb().length > 0) + ' after ' + (Date.now() - t0) + 'ms');

            // Visible upload spinner/progress indicator. Gemini is Angular Material, so the
            // in-progress affordance is likely a mat spinner / progressbar. Diagnostic dump too.
            const spinners = () => deepQueryAll([
              'mat-progress-spinner', 'mat-spinner', '.mat-mdc-progress-spinner', '.mdc-circular-progress',
              '[role="progressbar"]', 'circular-progress',
              '[class*="spinner" i]', '[class*="uploading" i]', '[class*="progress" i]',
            ]).filter(el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
            const s0 = spinners();
            clog('WAIT_UPLOAD: visible spinners=' + s0.length);
            s0.slice(0, 5).forEach((s, i) =>
              clog('  spinner[' + i + ']: <' + s.tagName.toLowerCase() + '> cls="' + (s.className || '').toString().slice(0, 60) + '"'));

            // Phase 2 — wait for the server upload to FINISH. Heuristic: at least a 4s floor
            // (covers normal uploads even if our spinner selectors miss), then break early once
            // no spinner is visible; hard cap 22s for big images / slow networks.
            const minWait = 4000, maxWait = 22000;
            const t1 = Date.now();
            while (Date.now() - t1 < maxWait) {
              const elapsed = Date.now() - t1;
              if (elapsed >= minWait && spinners().length === 0) break;
              await new Promise(r => setTimeout(r, 300));
            }
            clog('WAIT_UPLOAD: finished waiting (spinners=' + spinners().length + ', waited=' + (Date.now() - t1) + 'ms)');
          }

          // 2) Set text AFTER image is attached.
          //    Use collapse(false) so the cursor lands at the END of any existing
          //    content (including any inline image node), instead of replacing it.
          if (TEXT && input) {
            input.focus();
            if (input.isContentEditable) {
              const sel = window.getSelection();
              sel.removeAllRanges();
              const r = document.createRange();
              r.selectNodeContents(input);
              r.collapse(false);  // collapse to END — don't wipe existing nodes
              sel.addRange(r);
              document.execCommand('insertText', false, TEXT);
            } else {
              const proto = input instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
              const currentValue = input.value || '';
              setter.call(input, currentValue + TEXT);
              input.dispatchEvent(new Event('input', { bubbles: true }));
            }
            // Small settle delay so the editor's reactive state catches up before send
            await new Promise(r => setTimeout(r, 150));
          }

          // 3) Wait for send button to become enabled (image uploads can take 10–20s),
          //    then trigger send. Try a real click first; if button stays disabled past the
          //    deadline, click it anyway as a last-ditch attempt; finally fall back to a
          //    synthesized Enter on the input (some sites send via key event not button).
          const sendDeadline = Date.now() + ((IMAGE_B64 || WAIT_UPLOAD) ? 25000 : 3000);
          let lastBtn = null;
          let clicked = false;

          // Dispatch the full pointer/mouse event sequence (for sites that listen to them),
          // then trigger the click EXACTLY ONCE via el.click(). Calling both
          // dispatchEvent('click') AND el.click() fires the click handler twice — that
          // was causing ChatGPT to send the message twice.
          const fullClick = (el) => {
            const rect = el.getBoundingClientRect();
            const opts = {
              bubbles: true, cancelable: true,
              clientX: rect.left + rect.width / 2,
              clientY: rect.top + rect.height / 2,
              button: 0, view: window,
            };
            try { el.dispatchEvent(new PointerEvent('pointerdown', opts)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            try { el.dispatchEvent(new PointerEvent('pointerup', opts)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            try { el.click(); } catch (_) {}
          };

          while (Date.now() < sendDeadline) {
            const btn = pickFirst(cfg.sendSelectors);
            if (btn) {
              lastBtn = btn;
              const isDisabled = btn.disabled || btn.getAttribute('aria-disabled') === 'true';
              if (!isDisabled) {
                fullClick(btn);
                clicked = true;
                break;
              }
            }
            await new Promise(r => setTimeout(r, 200));
          }

          if (!clicked && lastBtn) {
            // Last-ditch: click anyway even if it still reports disabled.
            fullClick(lastBtn);
            clicked = true;
          }

          if (!clicked && input) {
            // Final fallback: simulate Enter on the input (some composers send on Enter).
            input.focus();
            input.dispatchEvent(new KeyboardEvent('keydown', {
              key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
              bubbles: true, cancelable: true,
            }));
          }

          // 4) Async completion poll. We detect "currently streaming" via EITHER:
          //    (a) a stop/cancel button is present in the composer area, OR
          //    (b) the send button is present but disabled.
          //    ChatGPT/Claude/Gemini all REPLACE send with stop during streaming, so (a)
          //    is the primary signal. We also keep (b) as a backup for sites that just
          //    disable the send button. Transition "streaming → not streaming" = done.
          (() => {
            // Force-paint nudge for occluded windows. Some sites (Gemini in particular) use
            // IntersectionObserver / Polymer lazy rendering — when our window is occluded,
            // the page reports the message container as "not visible" and skips rendering
            // new content. A tiny scroll nudge causes the observer to re-evaluate visibility
            // and the layer to repaint. Net-zero scroll position, harmless side effect.
            const paintNudge = () => {
              try {
                void document.body.offsetHeight;  // sync layout
                const sx = window.scrollX, sy = window.scrollY;
                window.scrollTo(sx, sy + 0.1);
                window.scrollTo(sx, sy);
                // Also nudge any inner scroll containers (Gemini's chat area is a custom element)
                document.querySelectorAll('[class*="scroll" i]').forEach(el => {
                  if (el.scrollHeight > el.clientHeight) {
                    const t = el.scrollTop;
                    el.scrollTop = t + 0.1;
                    el.scrollTop = t;
                  }
                });
              } catch (_) {}
            };

            // Stop-button selectors per host. Some sites (Gemini) put the stop button inside
            // shadow roots of Web Components, so we walk the whole DOM tree including shadowRoots.
            const STOP_SELECTORS = [
              // ChatGPT
              'button[data-testid="stop-button"]',
              'button[data-testid="composer-stop-button"]',
              // Claude (current UI)
              'button[aria-label="Stop response"]',
              'button[aria-label="Stop Response"]',
              'button[data-testid="stop-button"]',
              // Gemini (Material Design / mat-icon)
              'button[aria-label*="Stop generating" i]',
              'button[aria-label*="Stop response" i]',
              'button[mattooltip*="Stop" i]',
              'button.send-button[aria-label*="Stop" i]',
              // Generic catch-alls
              'button[aria-label*="Stop streaming" i]',
              'button[aria-label*="Stop" i]',
              'button[aria-label*="停止" i]',
              'button[aria-label*="중지" i]',
              'button[aria-label*="停止生成" i]',
            ];

            // Walk DOM + all shadow roots recursively. Gemini's Polymer/Lit components hide
            // the stop button inside shadowRoot of <chat-input>, <message-actions>, etc.
            const deepQuery = (selectors) => {
              const out = [];
              const stack = [document];
              while (stack.length) {
                const root = stack.pop();
                if (!root) continue;
                for (const sel of selectors) {
                  try {
                    const found = root.querySelectorAll?.(sel);
                    if (found) for (const el of found) out.push(el);
                  } catch (_) {}
                }
                const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
                for (const el of all) {
                  if (el.shadowRoot) stack.push(el.shadowRoot);
                }
              }
              return out;
            };

            // Element is "really visible" if it's not display:none, has non-zero size,
            // and isn't visibility:hidden. offsetParent alone is too permissive — Gemini's
            // per-message "Stop response" affordances pass offsetParent but have 0 height
            // until the user hovers their parent message.
            const isReallyVisible = (el) => {
              if (!el || el.offsetParent === null) return false;
              const rect = el.getBoundingClientRect();
              if (rect.width === 0 || rect.height === 0) return false;
              const style = window.getComputedStyle(el);
              if (style.visibility === 'hidden' || style.display === 'none') return false;
              return true;
            };

            const isCurrentlyStreaming = () => {
              // ONLY use stop-button presence as the streaming signal. We previously also
              // treated "send button disabled" as streaming, but Claude/Gemini disable the
              // send button whenever the input is empty (which it is right after we send).
              // That gave a false positive that lasted forever.
              const stops = deepQuery(STOP_SELECTORS);
              for (const el of stops) {
                if (isReallyVisible(el)) return true;
              }
              return false;
            };

            let wasStreaming = false;
            let lastDiagAt = 0;
            const start = Date.now();
            const maxWait = 5 * 60 * 1000;
            const pollMs = 500;
            const interval = setInterval(() => {
              // Every tick: nudge a paint. Cheap; only matters when window is occluded.
              paintNudge();

              if (Date.now() - start > maxWait) {
                clearInterval(interval);
                console.log('[Chorus] completion poll timed out');
                try {
                  window.webkit?.messageHandlers?.chorusCompletion?.postMessage({
                    host: location.hostname,
                    diagnostic: 'timeout-no-completion'
                  });
                } catch (_) {}
                return;
              }
              const streaming = isCurrentlyStreaming();
              if (streaming) {
                if (!wasStreaming) {
                  console.log('[Chorus] streaming started');
                  try {
                    window.webkit?.messageHandlers?.chorusCompletion?.postMessage({
                      host: location.hostname,
                      diagnostic: 'streaming-started'
                    });
                  } catch (_) {}
                }
                wasStreaming = true;
              } else if (wasStreaming) {
                clearInterval(interval);
                console.log('[Chorus] completion detected, posting to native');
                try {
                  window.webkit?.messageHandlers?.chorusCompletion?.postMessage({
                    host: location.hostname
                  });
                } catch (e) {
                  console.warn('[Chorus] postMessage failed', e);
                }
              } else {
                // Already streaming (wasStreaming=true) but isCurrentlyStreaming returned false
                // means we'd fall into the completion branch above — never reaches here.
                // (This branch is for the case where we never saw streaming start, which
                //  shouldn't happen now that all three sites detected it.)
              }

              // (heartbeat diagnostic removed — was useful for finding the Claude/Gemini
              //  stop-button bug, now noisy. streaming-started and completion are still logged.)
            }, pollMs);
          })();

          return clicked
            ? (imageAttached ? 'sent (with image)' : 'sent')
            : 'send button not found';
        })();
        """
    }

    /// Drives Gemini's "Upload & tools" → "Upload files" menu so it triggers its lazy
    /// <input type=file>. WebKit then calls our runOpenPanel delegate, which feeds the
    /// image silently. This script does NOT touch the file input itself — it just navigates
    /// the menu. It also dumps the menu contents (so we can see the real item labels) and
    /// logs each element's rect (so we can fall back to real CGEvent coordinate clicks if
    /// synthetic clicks don't carry enough user-activation to open the picker).
    static func geminiUploadTriggerScript() -> String {
        return """
        (async () => {
          const clog = (msg) => {
            try { window.webkit?.messageHandlers?.chorusJSLog?.postMessage(location.hostname + ': ' + msg); } catch (_) {}
          };
          const deepQueryAll = (selectors) => {
            const results = [];
            const stack = [document];
            while (stack.length) {
              const root = stack.pop();
              if (!root) continue;
              for (const sel of selectors) {
                try { const f = root.querySelectorAll?.(sel); if (f) for (const el of f) results.push(el); } catch (_) {}
              }
              const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
              for (const el of all) { if (el.shadowRoot) stack.push(el.shadowRoot); }
            }
            return [...new Set(results)];
          };
          const fullClick = (el) => {
            const r = el.getBoundingClientRect();
            const o = { bubbles: true, cancelable: true, clientX: r.left + r.width/2, clientY: r.top + r.height/2, button: 0, view: window };
            try { el.dispatchEvent(new PointerEvent('pointerdown', o)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mousedown', o));
            try { el.dispatchEvent(new PointerEvent('pointerup', o)); } catch (_) {}
            el.dispatchEvent(new MouseEvent('mouseup', o));
            try { el.click(); } catch (_) {}
          };
          const rectOf = (el) => { const r = el.getBoundingClientRect(); return Math.round(r.x)+','+Math.round(r.y)+' '+Math.round(r.width)+'x'+Math.round(r.height); };

          const sleep = (ms) => new Promise(r => setTimeout(r, ms));

          const findButton = () => {
            const b = deepQueryAll([
              'button[aria-label="Upload & tools"]',
              'button[aria-label*="Upload" i]',
              'button[aria-label*="Add files" i]',
              'button[aria-label*="上传" i]',
            ]);
            return b.length ? b[0] : null;
          };
          const findMenuItems = () => deepQueryAll([
            '[role="menuitem"]', 'button[mat-menu-item]', '[mat-menu-item]',
            '.mat-mdc-menu-panel button', '[role="menu"] button', '.cdk-overlay-pane button',
            '.cdk-overlay-pane [role="menuitem"]',
          ]);
          // Files = upload-from-computer. EXCLUDE cloud/other sources — Gemini's menu is a
          // grid (Files | Avatar | Drive | Photos | Notebooks); matching 'photo' once grabbed
          // "Google Photos" (an in-page picker) instead of the local-file upload.
          const isUploadItem = (raw) => {
            const t = raw.toLowerCase();
            if (t.includes('drive') || t.includes('photos') || t.includes('notebook') ||
                t.includes('avatar') || t.includes('personal intelligence')) return false;
            return /\\bfiles?\\b/.test(t) || t.includes('upload') ||
                   t.includes('from computer') || t.includes('上传') ||
                   t.includes('本地') || t.includes('文件');
          };
          const findUploadTile = () => {
            for (const it of findMenuItems()) {
              const t = ((it.textContent || '') + ' ' + (it.getAttribute('aria-label') || '')).trim();
              if (t && isUploadItem(t)) return it;
            }
            return null;
          };

          // 1. Poll for the "Upload & tools" button — the composer may still be rendering
          //    (cold start / slow machine), so don't assume it's there immediately.
          let btn = null;
          for (let i = 0; i < 20 && !btn; i++) { btn = findButton(); if (!btn) await sleep(150); }
          if (!btn) { clog('geminiUpload: NO upload button after ~3s'); return 'no-btn'; }

          // 2. Up to 2 attempts: click the button, then POLL (not a fixed sleep) for the
          //    upload tile to appear, then click it. Polling absorbs menu-open latency;
          //    the retry absorbs a missed first click / menu that opened then closed.
          for (let attempt = 1; attempt <= 2; attempt++) {
            clog('geminiUpload: attempt ' + attempt + ' — clicking upload btn (rect=' + rectOf(btn) + ')');
            fullClick(btn);

            let tile = null;
            for (let i = 0; i < 27 && !tile; i++) { tile = findUploadTile(); if (!tile) await sleep(150); }

            if (tile) {
              clog('geminiUpload: clicking "' + (tile.textContent || '').trim().slice(0, 40) + '" (rect=' + rectOf(tile) + ')');
              fullClick(tile);
              return 'clicked-item';
            }

            // Miss — dump what's actually in the menu so a future UI change is debuggable.
            const items = findMenuItems();
            clog('geminiUpload: attempt ' + attempt + ' found no upload tile among ' + items.length + ' items');
            items.slice(0, 12).forEach((it, i) => {
              const t = ((it.textContent || '') + ' | ' + (it.getAttribute('aria-label') || '')).trim();
              clog('  item[' + i + ']: "' + t.slice(0, 50) + '"');
            });
            await sleep(400);  // let any half-open menu settle before retrying
          }
          clog('geminiUpload: NO matching upload tile after 2 attempts');
          return 'no-item';
        })();
        """
    }
}
