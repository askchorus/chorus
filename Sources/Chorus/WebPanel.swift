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

/// Bridges JS `webkit.messageHandlers.chorusCompletion.postMessage({host})`
/// back to Swift. Singleton — same handler instance is attached to every WKWebView.
@MainActor
final class CompletionScriptHandler: NSObject, WKScriptMessageHandler {
    static let shared = CompletionScriptHandler()

    /// Called on main actor with the page hostname (e.g. "chatgpt.com").
    var onCompletion: ((String) -> Void)?

    private override init() { super.init() }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let host = body["host"] as? String else { return }
        // Diagnostic-only messages: log but don't count as completion.
        if let diag = body["diagnostic"] as? String {
            chorusLog.notice("[Chorus.Poll] \(host, privacy: .public) — \(diag, privacy: .public)")
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

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
    static func injectionScript(text: String, imageBase64: String? = nil, imageMime: String = "image/png") -> String {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        let imageJS = imageBase64.map { "\"\($0)\"" } ?? "null"
        let mimeJS = "\"\(imageMime)\""

        return """
        (async () => {
          const TEXT = "\(escapedText)";
          const IMAGE_B64 = \(imageJS);
          const IMAGE_MIME = \(mimeJS);

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
              // Gemini rejects synthesized paste/drop events — use the hidden file input.
              uploadMethod: 'fileInput',
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

          const cfg = HOSTS.find(c =>
            location.hostname === c.host || location.hostname.endsWith('.' + c.host)
          );
          if (!cfg) return 'host not supported: ' + location.hostname;

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
              const fileInputs = pickAll(cfg.fileInputSelectors || []);
              for (const fi of fileInputs) {
                try {
                  const dt = new DataTransfer();
                  dt.items.add(file);
                  fi.files = dt.files;
                  fi.dispatchEvent(new Event('change', { bubbles: true }));
                  return true;
                } catch (e) { /* try next */ }
              }
              return false;
            };

            // Run primary strategy; on failure walk through remaining methods.
            const order = method === 'drop'
              ? [tryDrop, tryFileInput, tryPaste]
              : method === 'fileInput'
                ? [tryFileInput, tryPaste, tryDrop]
                : [tryPaste, tryFileInput, tryDrop];

            for (const fn of order) {
              if (fn()) { imageAttached = true; break; }
            }

            // Wait for the upload to register in the UI (composer shows attached file).
            // Bumped from 800ms to 1500ms because Claude's React state sometimes hadn't
            // committed the attachment yet at 800ms, causing send-before-image races.
            await new Promise(r => setTimeout(r, 1500));
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
          const sendDeadline = Date.now() + (IMAGE_B64 ? 25000 : 3000);
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
}
