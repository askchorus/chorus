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

/// Builds and caches WKWebViews. Used by `WebViewStore` to keep webview instances
/// alive across SwiftUI view rebuilds.
enum WebViewFactory {
    static func make(url: URL) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent: cookies/login survive app restart
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        webView.load(URLRequest(url: url))
        return webView
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
            return imageAttached ? 'sent via enter (with image)' : 'sent via enter';
          }

          return clicked
            ? (imageAttached ? 'sent (with image)' : 'sent')
            : 'send button not found';
        })();
        """
    }
}
