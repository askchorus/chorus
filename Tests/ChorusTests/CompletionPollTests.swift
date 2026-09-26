import XCTest
import WebKit
@testable import Chorus

/// Runs the real broadcast script (Broadcaster.injectionScript) against tiny fake chat pages in a
/// WKWebView — no network, no real site — to pin down when the completion poll reports "done".
/// The fake pages borrow each site's hostname (via baseURL) so the script picks that site's
/// selectors, and mimic just enough of its DOM: a composer, a send control, answer nodes.
@MainActor
final class CompletionPollTests: XCTestCase {
    private final class Sink: NSObject, WKScriptMessageHandler {
        var completions: [[String: Any]] = []   // chorusCompletion bodies without a "diagnostic"
        var diagnostics: [String] = []
        var logs: [String] = []
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if m.name == "chorusJSLog" { logs.append("\(m.body)"); return }
            guard let body = m.body as? [String: Any] else { return }
            if let d = body["diagnostic"] as? String { diagnostics.append(d) } else { completions.append(body) }
        }
    }

    private var keep: [AnyObject] = []

    private static func setSPI(_ target: NSObject, _ selectors: [String]) {
        typealias Setter = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        for name in selectors {
            let sel = NSSelectorFromString(name)
            guard target.responds(to: sel) else { continue }
            unsafeBitCast(target.method(for: sel), to: Setter.self)(target, sel, ObjCBool(false))
        }
    }

    /// Loads `page` as if served from `host`, sends `text` through the real script, then waits
    /// up to `seconds` for `done`. Returns what the page reported and when (seconds after send).
    /// With `focus`, focus mode's stylesheet is applied first and `focusCheck` (a JS expression)
    /// is evaluated 0.2s after it — time for the page to re-measure its bottom bar, as the real
    /// sites do — before sending.
    private func send(page: String, host: String, text: String = "三个名字", seconds: TimeInterval,
                      focus: Bool = false, focusCheck: String? = nil, checked: ((Any?) -> Void)? = nil,
                      until done: @escaping @MainActor (Sink) -> Bool = { !$0.completions.isEmpty }) async throws -> (Sink, TimeInterval?) {
        let sink = Sink()
        let config = WKWebViewConfiguration()
        config.userContentController.add(sink, name: "chorusCompletion")
        config.userContentController.add(sink, name: "chorusJSLog")
        // The same SPI switches the app flips on its panels (WebViewFactory): with no window,
        // WebKit would otherwise treat the page as hidden and clamp the poll's timers.
        Self.setSPI(config.preferences, ["_setPageVisibilityBasedProcessSuppressionEnabled:",
                                         "_setHiddenPageDOMTimerThrottlingEnabled:",
                                         "_setHiddenPageDOMTimerThrottlingAutoIncreases:"])
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        Self.setSPI(web, ["_setWindowOcclusionDetectionEnabled:"])
        keep += [web, sink]
        web.loadHTMLString(page, baseURL: URL(string: "https://\(host)/")!)
        for _ in 0..<50 {   // wait for the fake page's script to run
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!window.__fakeReady")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if focus {
            _ = try await web.evaluateJavaScript(FocusMode.addJS + ";true")
            if let focusCheck {
                checked?(try await web.callAsyncJavaScript("await new Promise(r => setTimeout(r, 200)); return (\(focusCheck));",
                                                           arguments: [:], in: nil, contentWorld: .page))
            }
        }
        let start = Date()
        web.evaluateJavaScript(Broadcaster.injectionScript(text: text), completionHandler: nil)
        while Date().timeIntervalSince(start) < seconds {
            if done(sink) { return (sink, Date().timeIntervalSince(start)) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return (sink, nil)
    }

    /// Loads `page` as if served from `host` and returns the webview once its script has run.
    private func load(_ page: String, host: String) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        Self.setSPI(config.preferences, ["_setPageVisibilityBasedProcessSuppressionEnabled:",
                                         "_setHiddenPageDOMTimerThrottlingEnabled:",
                                         "_setHiddenPageDOMTimerThrottlingAutoIncreases:"])
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        keep.append(web)
        web.loadHTMLString(page, baseURL: URL(string: "https://\(host)/")!)
        // about:blank is "complete" too — wait for OUR page, served as `host`.
        for _ in 0..<50 {
            if (try? await web.evaluateJavaScript("location.hostname === '\(host)' && document.readyState === 'complete'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return web
    }

    // A DeepSeek-shaped page: a textarea, the circular role=button send DIV, .ds-markdown answers.
    // `answer` decides what a send does: "instant" appends the whole answer at once; "none" does
    // nothing but clear the composer.
    private func deepseekPage(answer: String, shell: Bool = false) -> String {
        let composer = """
        <textarea></textarea>
        <div role="button" class="ds-button ds-button--primary ds-button--circle">↑</div>
        """
        let body = shell ? """
        <div class="c3ecdb44">
          <div class="dc04ec1d"><div class="ca6d4be1" style="position:fixed">🐳 ☰ 🔍 ⊕</div></div>
          <div class="_7780f2e"><div class="_765a5cd">
            <div class="_2be88ba"><div class="_1aa2651 the-header">小猫名字</div></div>
            <div class="ds-virtual-list">
              <div class="ds-virtual-list-items" id="chat"></div>
              <div class="_871cbca" style="position:sticky;bottom:0">\(composer)<div>内容由 AI 生成，请仔细甄别</div></div>
            </div>
          </div></div>
        </div>
        """ : """
        <div id="chat"></div>
        \(composer)
        """
        return """
        <!doctype html><html><body>
        \(body)
        <script>
        document.querySelector('[role=button]').addEventListener('click', () => {
          const ta = document.querySelector('textarea');
          if (!ta.value.trim()) return;
          ta.value = '';
          if ('\(answer)' === 'instant') {
            const d = document.createElement('div'); d.className = 'ds-markdown'; d.textContent = '奶糖 布丁 团子';
            document.getElementById('chat').appendChild(d);
          }
        });
        window.__fakeReady = true;
        </script></body></html>
        """
    }

    // A ChatGPT-shaped page (a site whose stop button the poll trusts), with one earlier answer
    // already on the page. "instant" answers at once; "stream" shows the stop button (inside the
    // input box, as on the real site) and grows the answer for ~2.4s; "none" answers nothing.
    // `shell` wraps it in ChatGPT's real app shell: top bar, thread frame, composer form.
    // `notice` goes in the slot ChatGPT keeps above its input box for limit banners. The shell's
    // bottom bar is measured into --thread-scroll-padding-bottom (plus 16px), as ChatGPT does.
    private func chatgptPage(answer: String, shell: Bool = false, notice: String = "") -> String {
        let body = shell ? """
        <aside data-app-shell-left-panel-appearance="default">chat history</aside>
        <nav data-app-navigation-rail="true">rail</nav>
        <header data-app-shell-titlebar="true" style="position:fixed;top:0;height:52px">ChatGPT 5 ▾</header>
        <div data-app-shell-thread-edge-divider="false" style="margin-top:52px">
          <div class="thread-scroll-container" style="position:relative; --spacing:4px; --thread-scroll-padding-bottom:127px">
            <div id="chat"><div class="markdown">an earlier answer</div></div>
            <div data-markdown-copy="exclude" class="text-center text-xs">ChatGPT can make mistakes.</div>
            <div class="spacer" aria-hidden="true" style="position:sticky;bottom:0;height:calc(var(--thread-scroll-padding-bottom) - var(--spacing) * 4)"></div>
            <div data-thread-scroll-footer="true" style="position:absolute;left:0;right:0;bottom:0;padding-bottom:24px">
              <form data-chatgpt-composer="" style="position:relative;display:flex;flex-direction:column" onsubmit="event.preventDefault()">
                <div data-above-composer-portal="">\(notice)</div>
                <div class="card" style="position:relative;height:87px;background:#fff">
                  <div class="ProseMirror" contenteditable="true" data-composer-markdown="true"></div>
                  <button data-testid="send-button">send</button>
                </div>
              </form>
            </div>
          </div>
        </div>
        """ : """
        <div id="chat"><div class="markdown">an earlier answer</div></div>
        <div id="prompt-textarea" contenteditable="true"></div>
        <button data-testid="send-button">send</button>
        """
        return """
        <!doctype html><html><body><main data-app-shell-main-surface="browser" style="border-left:0.5px solid #ccc">
        \(body)
        </main>
        <script>
        const bar = document.querySelector('[data-thread-scroll-footer]'), thread = document.querySelector('.thread-scroll-container');
        if (bar) setInterval(() => thread.style.setProperty('--thread-scroll-padding-bottom', (bar.offsetHeight + 16) + 'px'), 50);
        document.querySelector('[data-testid=send-button]').addEventListener('click', () => {
          const ed = document.querySelector('[data-thread-scroll-footer] [contenteditable="true"]') || document.getElementById('prompt-textarea');
          if (!ed.innerText.trim()) return;
          ed.innerHTML = '';
          const mode = '\(answer)';
          if (mode === 'none') return;
          const d = document.createElement('div'); d.className = 'markdown';
          document.getElementById('chat').appendChild(d);
          if (mode === 'instant') { d.textContent = '糯米 团子 小满'; return; }
          const stop = document.createElement('button'); stop.setAttribute('data-testid', 'stop-button'); stop.textContent = '■';
          (document.querySelector('form .card') || document.querySelector('main')).appendChild(stop);
          let n = 0;
          const t = setInterval(() => {
            d.textContent += '团子 ';
            if (++n === 8) { clearInterval(t); stop.remove(); }
          }, 300);
        });
        window.__fakeReady = true;
        </script></body></html>
        """
    }

    // A Gemini-shaped page in Gemini's real shell: account bar, top bar, side nav, chat history,
    // the input-container (whose send button turns into the stop button while answering).
    private func geminiPage() -> String {
        """
        <!doctype html><html><body>
        <div class="boqOnegoogleliteOgbOneGoogleBar" style="position:absolute;top:8px">
          <a href="https://accounts.google.com/SignOutOptions">account</a></div>
        <chat-app style="display:block;padding-top:68px">
          <div class="side-nav-menu-button" style="position:fixed">☰ Pro</div>
          <top-bar-actions style="display:block;position:fixed">⋮</top-bar-actions>
          <main class="chat-app">
            <bard-sidenav style="display:block">history</bard-sidenav>
            <div class="chat-container" style="position:relative;height:600px;display:flex;flex-direction:column">
              <div id="chat-history" style="flex:1"><div id="chat"><div class="markdown">an earlier answer</div></div>
                <hallucination-disclaimer style="display:block">Gemini is AI and can make mistakes.</hallucination-disclaimer></div>
              <input-container style="display:block;position:relative;height:92px;background:#faf9f9">
                <div class="input-area-container">
                  <rich-textarea><div class="ql-editor" contenteditable="true"></div></rich-textarea>
                  <button aria-label="Send message">send</button>
                </div>
              </input-container>
            </div>
          </main>
        </chat-app>
        <script>
        document.querySelector('[aria-label="Send message"]').addEventListener('click', () => {
          const ed = document.querySelector('.ql-editor');
          if (!ed.innerText.trim()) return;
          ed.innerHTML = '';
          const d = document.createElement('div'); d.className = 'markdown';
          document.getElementById('chat').appendChild(d);
          const stop = document.createElement('button'); stop.setAttribute('aria-label', 'Stop response'); stop.textContent = '■';
          document.querySelector('.input-area-container').appendChild(stop);
          let n = 0;
          const t = setInterval(() => {
            d.textContent += '汤圆 ';
            if (++n === 8) { clearInterval(t); stop.remove(); }
          }, 300);
        });
        window.__fakeReady = true;
        </script></body></html>
        """
    }

    /// The bug: DeepSeek answered a one-liner in ~1s, before the poll first looked; no stop button
    /// or growth was ever seen and the batch sat until the ~90s safety net. Now the first look
    /// spots the new answer and starts the text-settle clock straight away.
    func testDeepSeekAnswerFinishedBeforeFirstLookIsNoticed() async throws {
        let (sink, t) = try await send(page: deepseekPage(answer: "instant"), host: "chat.deepseek.com", seconds: 6, until: { s in
            s.logs.contains { $0.contains("answer already on the page at first look") }
        })
        XCTAssertNotNil(t, "first look didn't notice the finished answer; logs: \(sink.logs)")
    }

    func testDeepSeekNothingAnsweredIsNotMistakenForDone() async throws {
        let (sink, t) = try await send(page: deepseekPage(answer: "none"), host: "chat.deepseek.com", seconds: 5, until: { s in
            s.logs.contains { $0.contains("answer already on the page") } || !s.completions.isEmpty
        })
        XCTAssertNil(t, "reported an answer that never came; logs: \(sink.logs)")
    }

    /// Where the stop button is trusted, an answer that was already complete is reported within
    /// a few seconds (send-verify ~1.5s + a first look + two quiet ticks).
    func testTrustedSiteInstantAnswerCompletesQuickly() async throws {
        let (sink, t) = try await send(page: chatgptPage(answer: "instant"), host: "chatgpt.com", seconds: 8)
        XCTAssertNotNil(t, "no completion; logs: \(sink.logs)")
        if let t { XCTAssertLessThan(t, 6.5) }
    }

    func testTrustedSiteNothingAnsweredIsNotMistakenForDone() async throws {
        let (sink, t) = try await send(page: chatgptPage(answer: "none"), host: "chatgpt.com", seconds: 6)
        XCTAssertNil(t, "completed without an answer; logs: \(sink.logs)")
    }

    // MARK: Focus mode

    /// Focus mode hides ChatGPT's input box, but sending through it and watching the stop button
    /// inside it must still work: both first check that the element is rendered, which is why
    /// the box is made transparent and click-through rather than display:none. Lifted out of the
    /// bottom bar, it leaves ChatGPT's own measurement of that bar with nothing to reserve room for.
    func testFocusModeHidesChatGPTChromeButSendAndStopStillWork() async throws {
        var styles: [String: String] = [:]
        let check = """
        JSON.stringify({ composer: getComputedStyle(document.querySelector('form .card')).opacity,
                         lifted: getComputedStyle(document.querySelector('form .card')).position,
                         clicks: getComputedStyle(document.querySelector('form [contenteditable]')).pointerEvents,
                         header: getComputedStyle(document.querySelector('header')).display,
                         sidebar: getComputedStyle(document.querySelector('aside')).display,
                         rail: getComputedStyle(document.querySelector('nav')).display,
                         border: getComputedStyle(document.querySelector('main')).borderLeftWidth,
                         spacer: getComputedStyle(document.querySelector('.spacer')).height,
                         frameTop: getComputedStyle(document.querySelector('[data-app-shell-thread-edge-divider]')).marginTop,
                         disclaimer: getComputedStyle(document.querySelector('[data-markdown-copy]')).display })
        """
        let (sink, t) = try await send(page: chatgptPage(answer: "stream", shell: true), host: "chatgpt.com", seconds: 10,
                                       focus: true, focusCheck: check) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["composer": "0", "lifted": "absolute", "clicks": "none", "header": "none", "sidebar": "none",
                                "rail": "none", "border": "0px", "spacer": "0px", "frameTop": "0px", "disclaimer": "none"])
        XCTAssertNotNil(t, "no completion with focus mode on; logs: \(sink.logs)")
        XCTAssertTrue(sink.diagnostics.contains("streaming-started"), "stop button not seen under focus mode; logs: \(sink.logs)")
        if let t { XCTAssertGreaterThan(t, 2.4, "declared done while still streaming") }
    }

    /// Signed out, ChatGPT's top bar holds the Log in button, so focus mode leaves it (and the
    /// room made for it) alone.
    func testFocusModeKeepsChatGPTTopBarWhileSignedOut() async throws {
        var styles: [String: String] = [:]
        let page = chatgptPage(answer: "none", shell: true)
            .replacingOccurrences(of: "ChatGPT 5 ▾", with: "<button data-testid=\"login-button\">Log in</button>")
        let check = """
        JSON.stringify({ header: getComputedStyle(document.querySelector('header')).display,
                         frameTop: getComputedStyle(document.querySelector('[data-app-shell-thread-edge-divider]')).marginTop })
        """
        _ = try await send(page: page, host: "chatgpt.com", seconds: 0.1, focus: true, focusCheck: check) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["header": "block", "frameTop": "52px"])
    }

    /// A notice ChatGPT puts above its input box (a usage limit) stays in view and clickable, and
    /// the room ChatGPT measures for its bottom bar is now exactly the notice's.
    func testFocusModeKeepsChatGPTNoticesInView() async throws {
        let notice = #"<div class="notice" style="height:48px">You've hit the Free plan limit <button class="upgrade">Upgrade</button></div>"#
        var styles: [String: String] = [:]
        _ = try await send(page: chatgptPage(answer: "none", shell: true, notice: notice), host: "chatgpt.com", seconds: 0.1,
                           focus: true, focusCheck: """
        JSON.stringify({ notice: (() => { for (let e = document.querySelector('.notice'); e; e = e.parentElement) {
                             const cs = getComputedStyle(e); if (cs.opacity !== '1' || cs.display === 'none' || cs.visibility === 'hidden') return 'hidden';
                           } return 'shown'; })(),
                         clicks: getComputedStyle(document.querySelector('.upgrade')).pointerEvents,
                         room: getComputedStyle(document.querySelector('.thread-scroll-container')).getPropertyValue('--thread-scroll-padding-bottom').trim(),
                         box: getComputedStyle(document.querySelector('form .card')).opacity })
        """) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["notice": "shown", "clicks": "auto", "room": "64px", "box": "0"])
    }

    /// ChatGPT's composer no longer carries #prompt-textarea. With a message's edit box open
    /// higher up the page, the broadcast still types into the composer at the bottom.
    func testChatGPTTypesIntoTheComposerNotAnOpenEditBox() async throws {
        let page = chatgptPage(answer: "instant", shell: true)
            .replacingOccurrences(of: #"<div id="chat">"#, with: """
            <div id="chat"><div data-content-search-unit-key="t:0:user"><form class="edit" data-chatgpt-composer=""><div class="editcard"><div contenteditable="true">edited</div></div></form></div>
            """)
        let (sink, t) = try await send(page: page, host: "chatgpt.com", seconds: 10)
        XCTAssertNotNil(t, "the question never reached the composer; logs: \(sink.logs)")
    }

    /// Gemini's input box is also lifted out of the page flow (so the chat fills the pane); the
    /// send and the stop-button watch inside it must still work.
    func testFocusModeHidesGeminiChromeButSendAndStopStillWork() async throws {
        var styles: [String: String] = [:]
        let check = """
        JSON.stringify({ bar: getComputedStyle(document.querySelector('.boqOnegoogleliteOgbOneGoogleBar')).display,
                         menu: getComputedStyle(document.querySelector('.side-nav-menu-button')).display,
                         actions: getComputedStyle(document.querySelector('top-bar-actions')).display,
                         sidenav: getComputedStyle(document.querySelector('bard-sidenav')).display,
                         top: getComputedStyle(document.querySelector('chat-app')).paddingTop,
                         input: getComputedStyle(document.querySelector('input-container')).position,
                         box: getComputedStyle(document.querySelector('.input-area-container')).opacity,
                         clicks: getComputedStyle(document.querySelector('.ql-editor')).pointerEvents,
                         disclaimer: getComputedStyle(document.querySelector('hallucination-disclaimer')).display })
        """
        let (sink, t) = try await send(page: geminiPage(), host: "gemini.google.com", seconds: 10,
                                       focus: true, focusCheck: check) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["bar": "none", "menu": "none", "actions": "none", "sidenav": "none", "top": "0px",
                                "input": "absolute", "box": "0", "clicks": "none", "disclaimer": "none"])
        XCTAssertNotNil(t, "no completion with focus mode on; logs: \(sink.logs)")
        XCTAssertTrue(sink.diagnostics.contains("streaming-started"), "stop button not seen under focus mode; logs: \(sink.logs)")
        if let t { XCTAssertGreaterThan(t, 2.4, "declared done while still streaming") }
    }

    /// DeepSeek's classes are hashed per release; focus mode finds its bars by the stable
    /// hooks (.the-header, .ds-virtual-list, the textarea) and the fast-answer path still works.
    func testFocusModeHidesDeepSeekChromeButSendStillWorks() async throws {
        var styles: [String: String] = [:]
        let check = """
        JSON.stringify({ header: getComputedStyle(document.querySelector('._2be88ba')).display,
                         main: getComputedStyle(document.querySelector('._7780f2e')).display,
                         list: getComputedStyle(document.querySelector('.ds-virtual-list')).display,
                         composer: getComputedStyle(document.querySelector('._871cbca')).opacity,
                         room: getComputedStyle(document.querySelector('._871cbca')).height,
                         clicks: getComputedStyle(document.querySelector('[role=button]')).pointerEvents,
                         answers: getComputedStyle(document.querySelector('.ds-virtual-list-items')).opacity })
        """
        let (sink, t) = try await send(page: deepseekPage(answer: "instant", shell: true), host: "chat.deepseek.com", seconds: 6,
                                       focus: true, focusCheck: check, checked: { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }) { s in
            s.logs.contains { $0.contains("answer already on the page at first look") }
        }
        XCTAssertEqual(styles, ["header": "none", "main": "block", "list": "block", "composer": "0", "room": "0px",
                                "clicks": "none", "answers": "1"])
        XCTAssertNotNil(t, "first look didn't notice the answer under focus mode; logs: \(sink.logs)")
    }

    /// Regression: an answer with web search puts a sources panel (its own .ds-virtual-list) next
    /// to the conversation. A structural rule once read that as the page layout and hid the whole
    /// conversation list — the pane went blank with the answer on the page. The conversation, and
    /// anything holding an answer, must stay visible whatever else is on the page.
    func testFocusModeNeverHidesDeepSeekConversation() async throws {
        let page = deepseekPage(answer: "none", shell: true)
            .replacingOccurrences(of: #"<div class="ds-virtual-list-items" id="chat"></div>"#,
                                  with: #"<div class="ds-virtual-list-items" id="chat"><div class="ds-message"><div class="ds-markdown">鼻炎针有两类</div></div></div>"#)
            // A third child of the main column, after the list: the sources panel.
            .replacingOccurrences(of: "</div></div>\n</div>",
                                  with: #"<div class="sources"><div><div class="ds-virtual-list">来源 1 · 来源 2</div></div></div>"# + "</div></div>\n</div>")
        XCTAssertTrue(page.contains("sources"), "fixture didn't get its sources panel")
        var styles: [String: String] = [:]
        let check = """
        JSON.stringify({ list: getComputedStyle(document.querySelector('.ds-virtual-list')).display,
                         answer: String(document.querySelector('.ds-markdown').getBoundingClientRect().height > 0),
                         answerOpacity: getComputedStyle(document.querySelector('.ds-markdown')).opacity,
                         header: getComputedStyle(document.querySelector('._2be88ba')).display })
        """
        _ = try await send(page: page, host: "chat.deepseek.com", seconds: 0.1, focus: true, focusCheck: check) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["list": "block", "answer": "true", "answerOpacity": "1", "header": "none"])
    }

    /// Editing a sent message opens an input box inside the conversation. Focus mode hides only
    /// the one at the bottom, never those (DeepSeek and ChatGPT alike).
    func testFocusModeLeavesEditBoxesInTheConversationAlone() async throws {
        let deepseek = deepseekPage(answer: "none", shell: true)
            .replacingOccurrences(of: #"<div class="ds-virtual-list-items" id="chat"></div>"#, with: """
            <div class="ds-virtual-list-items" id="chat"><div class="ds-message"><div class="edit"><div><div><div class="e4"><textarea>my question, edited</textarea></div></div></div></div></div></div>
            """)
        var dsStyles: [String: String] = [:]
        _ = try await send(page: deepseek, host: "chat.deepseek.com", seconds: 0.1, focus: true, focusCheck: """
        JSON.stringify({ edit: getComputedStyle(document.querySelector('.edit')).opacity,
                         editClicks: getComputedStyle(document.querySelector('.edit textarea')).pointerEvents,
                         composer: getComputedStyle(document.querySelector('._871cbca')).opacity })
        """) { v in
            dsStyles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(dsStyles, ["edit": "1", "editClicks": "auto", "composer": "0"])

        let chatgpt = chatgptPage(answer: "none", shell: true)
            .replacingOccurrences(of: #"<div id="chat">"#, with: """
            <div id="chat"><div data-content-search-unit-key="t:0:user"><form class="edit" data-chatgpt-composer=""><div class="editcard"><div contenteditable="true">edited</div></div></form></div>
            """)
        var gptStyles: [String: String] = [:]
        _ = try await send(page: chatgpt, host: "chatgpt.com", seconds: 0.1, focus: true, focusCheck: """
        JSON.stringify({ edit: getComputedStyle(document.querySelector('.editcard')).opacity,
                         editClicks: getComputedStyle(document.querySelector('.editcard [contenteditable]')).pointerEvents,
                         editPlace: getComputedStyle(document.querySelector('.editcard')).position,
                         composer: getComputedStyle(document.querySelector('[data-thread-scroll-footer] form .card')).opacity })
        """) { v in
            gptStyles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(gptStyles, ["edit": "1", "editClicks": "auto", "editPlace": "static", "composer": "0"])
    }

    // A claude.ai-shaped chat page: floating title bar over a 48px padding, collapsed sidebar, the
    // tail of the transcript (sentinel, 48px spacer, the room kept for notices) and the input
    // container. Its fieldset holds the notices layer, just above the card around the editor (the
    // stop button appears in the card while answering). Like Claude, the page measures its
    // notices into that room.
    private func claudePage(notice: String = "") -> String {
        """
        <!doctype html><html><body>
        <aside class="dframe-sidebar" aria-label="Sidebar" style="position:absolute"><button data-testid="sidebar-compact-trigger">☰</button></aside>
        <div class="col" style="padding-top:48px;position:relative">
          <div class="dframe-header" data-testid="chat-header" style="position:absolute;top:0;height:48px">Unidentified object inquiry · Share</div>
          <div data-testid="chat-column-body">
            <div id="chat"><div data-testid="user-message">earlier question</div>
              <div data-is-streaming="false"><div class="font-claude-response"><div class="standard-markdown">earlier answer</div></div></div></div>
            <div data-testid="last-message-sentinel" style="height:1px"></div>
            <div class="h-12" style="height:48px"></div>
            <div data-composer-banners-room="" style="height:var(--composer-banners-composer-h, 0px)"></div>
            <div data-chat-input-container="true" style="position:sticky;bottom:0;padding-top:24px">
              <div style="position:relative;height:0"><div data-testid="transcript-bottom-fade" style="position:absolute;left:0;right:0;bottom:0;height:48px"></div></div>
              <div data-cds="ChatComposerDock"><div role="presentation"><fieldset style="display:flex;flex-direction:column;border:0;margin:0;padding:0">
                <div style="position:relative;height:0"><div data-composer-banner-layer="" style="position:absolute;left:0;right:0;bottom:0">\(notice)</div></div>
                <div class="card-backdrop" style="position:relative;background:#fff">
                  <div data-tap-focuses-field="" style="min-height:100px">
                    <div contenteditable="true" class="tiptap ProseMirror" data-testid="chat-input"></div>
                    <button aria-label="Send message">↑</button>
                  </div>
                </div>
              </fieldset></div></div>
              <div role="note" data-disclaimer="true">Claude is AI and can make mistakes.</div>
            </div>
          </div>
        </div>
        <script>
        const layer = document.querySelector('[data-composer-banner-layer]'), room = document.querySelector('[data-composer-banners-room]');
        setInterval(() => room.style.setProperty('--composer-banners-composer-h', layer.offsetHeight + 'px'), 50);
        document.querySelector('[aria-label="Send message"]').addEventListener('click', () => {
          const ed = document.querySelector('[data-testid="chat-input"]');
          if (!ed.innerText.trim()) return;
          ed.innerHTML = '';
          const r = document.createElement('div'); r.setAttribute('data-is-streaming', 'true');
          r.innerHTML = '<div class="font-claude-response"><div class="standard-markdown"></div></div>';
          document.getElementById('chat').appendChild(r);
          const md = r.querySelector('.standard-markdown');
          const stop = document.createElement('button'); stop.setAttribute('aria-label', 'Stop response'); stop.textContent = '■';
          document.querySelector('[data-tap-focuses-field]').appendChild(stop);
          let n = 0;
          const t = setInterval(() => {
            md.textContent += 'Mochi ';
            if (++n === 8) { clearInterval(t); stop.remove(); r.setAttribute('data-is-streaming', 'false'); }
          }, 300);
        });
        window.__fakeReady = true;
        </script></body></html>
        """
    }

    /// Claude: title bar, sidebar button, input box and disclaimer hidden; the answer stays and
    /// runs to 16px above the bottom; the send and the stop-button watch inside the transparent
    /// card still work.
    func testFocusModeHidesClaudeChromeButSendAndStopStillWork() async throws {
        var styles: [String: String] = [:]
        let check = """
        JSON.stringify({ header: getComputedStyle(document.querySelector('[data-testid="chat-header"]')).display,
                         room: getComputedStyle(document.querySelector('.col')).paddingTop,
                         sidebar: getComputedStyle(document.querySelector('aside')).display,
                         box: getComputedStyle(document.querySelector('.card-backdrop')).opacity,
                         lifted: getComputedStyle(document.querySelector('.card-backdrop')).position,
                         inputRoom: getComputedStyle(document.querySelector('[data-chat-input-container]')).paddingTop,
                         clicks: getComputedStyle(document.querySelector('[data-testid="chat-input"]')).pointerEvents,
                         disclaimer: getComputedStyle(document.querySelector('[data-disclaimer]')).display,
                         spacer: getComputedStyle(document.querySelector('.h-12')).height,
                         fade: getComputedStyle(document.querySelector('[data-testid="transcript-bottom-fade"]')).display,
                         answer: getComputedStyle(document.querySelector('.font-claude-response')).opacity })
        """
        let (sink, t) = try await send(page: claudePage(), host: "claude.ai", seconds: 10,
                                       focus: true, focusCheck: check, checked: { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        })
        XCTAssertEqual(styles, ["header": "none", "room": "0px", "sidebar": "none", "box": "0", "lifted": "absolute",
                                "inputRoom": "0px", "clicks": "none", "disclaimer": "none", "spacer": "16px", "fade": "none",
                                "answer": "1"])
        XCTAssertNotNil(t, "no completion with focus mode on; logs: \(sink.logs)")
        XCTAssertTrue(sink.diagnostics.contains("streaming-started"), "stop button not seen under focus mode; logs: \(sink.logs)")
        if let t { XCTAssertGreaterThan(t, 2.4, "declared done while still streaming") }
    }

    /// Claude's notices ("You've used 75% of your weekly limit") share the input box's fieldset.
    /// Focus mode keeps them in view and clickable, in the room Claude keeps for them below the
    /// conversation, clear of the last answer.
    func testFocusModeKeepsClaudeNoticesInView() async throws {
        let notice = #"<div class="notice" style="height:52px">You've used 75% of your weekly limit <button aria-label="Dismiss">×</button></div>"#
        var styles: [String: String] = [:]
        _ = try await send(page: claudePage(notice: notice), host: "claude.ai", seconds: 0.1, focus: true, focusCheck: """
        JSON.stringify({ notice: (() => { for (let e = document.querySelector('.notice'); e; e = e.parentElement) {
                             const cs = getComputedStyle(e); if (cs.opacity !== '1' || cs.display === 'none' || cs.visibility === 'hidden') return 'hidden';
                           } return 'shown'; })(),
                         clicks: getComputedStyle(document.querySelector('[aria-label="Dismiss"]')).pointerEvents,
                         room: getComputedStyle(document.querySelector('[data-composer-banners-room]')).height,
                         clear: String(document.querySelector('.notice').getBoundingClientRect().top >= document.querySelector('#chat').getBoundingClientRect().bottom),
                         box: getComputedStyle(document.querySelector('.card-backdrop')).opacity })
        """) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["notice": "shown", "clicks": "auto", "room": "52px", "clear": "true", "box": "0"])
    }

    /// Claude's new-chat page: a stacked <header> and the fieldset around the chat input. Only the
    /// card goes (it stays in place there); a fieldset without that card is hidden whole.
    func testFocusModeHidesClaudeNewChatChrome() async throws {
        let page = """
        <!doctype html><html><body>
        <header class="dframe-header">New chat · incognito</header>
        <div class="dock"><div><div role="presentation"><fieldset>
          <div style="position:relative;height:0"><div data-composer-banner-layer=""></div></div>
          <div class="card-backdrop"><div data-tap-focuses-field="">
            <div contenteditable="true" class="tiptap ProseMirror" data-testid="chat-input"></div><button aria-label="Send message">↑</button>
          </div></div>
        </fieldset></div></div></div>
        <h1 class="greeting">How can I help you today?</h1>
        <script>window.__fakeReady = true;</script></body></html>
        """
        let check = """
        JSON.stringify({ header: getComputedStyle(document.querySelector('header')).display,
                         box: getComputedStyle(document.querySelector('.card-backdrop')).opacity,
                         place: getComputedStyle(document.querySelector('.card-backdrop')).position,
                         fieldset: getComputedStyle(document.querySelector('fieldset')).opacity,
                         greeting: getComputedStyle(document.querySelector('.greeting')).opacity })
        """
        var styles: [String: String] = [:]
        _ = try await send(page: page, host: "claude.ai", seconds: 0.1, focus: true, focusCheck: check) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["header": "none", "box": "0", "place": "static", "fieldset": "1", "greeting": "1"])

        var fallback: [String: String] = [:]
        _ = try await send(page: page.replacingOccurrences(of: #" data-tap-focuses-field="""#, with: ""), host: "claude.ai",
                           seconds: 0.1, focus: true, focusCheck: check) { v in
            fallback = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(fallback, ["header": "none", "box": "1", "place": "static", "fieldset": "0", "greeting": "1"])
    }

    /// DeepSeek's new-chat page has no conversation list; its input box (the same component, four
    /// levels above the textarea) is hidden there too, and sending through it still works.
    func testFocusModeHidesDeepSeekHomeComposerButSendStillWorks() async throws {
        let home = deepseekPage(answer: "instant").replacingOccurrences(of: """
        <textarea></textarea>
        <div role="button" class="ds-button ds-button--primary ds-button--circle">↑</div>
        """, with: """
        <div class="_9a2f8e4"><div class="_5758a85">How can I help you today?</div>
          <div class="aaff8b8f"><div class="_77cefa5"><div class="_020ab5b">
            <div class="_24fad49"><textarea></textarea></div>
            <div class="ec4f5d61"><div role="button" class="ds-button ds-button--primary ds-button--circle">↑</div></div>
          </div></div></div></div>
        """)
        XCTAssertTrue(home.contains("aaff8b8f"), "fixture didn't take the home-page shape")
        var styles: [String: String] = [:]
        let check = """
        JSON.stringify({ box: getComputedStyle(document.querySelector('.aaff8b8f')).opacity,
                         clicks: getComputedStyle(document.querySelector('[role=button]')).pointerEvents,
                         greeting: getComputedStyle(document.querySelector('._5758a85')).opacity })
        """
        let (sink, t) = try await send(page: home, host: "chat.deepseek.com", seconds: 6,
                                       focus: true, focusCheck: check, checked: { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }) { s in
            s.logs.contains { $0.contains("answer already on the page at first look") }
        }
        XCTAssertEqual(styles, ["box": "0", "clicks": "none", "greeting": "1"])
        XCTAssertNotNil(t, "first look didn't notice the answer from the home page; logs: \(sink.logs)")
    }

    // MARK: Reading answers back (summarize, share card, agent bridge)

    /// ChatGPT's 2026 app shell dropped data-message-author-role; its answers are MarkdownRoot
    /// blocks inside the turn's unit. The whole last answer comes back — every block of it, not
    /// an earlier answer and not the question.
    func testExtractsChatGPTAnswerFromTheAppShell() async throws {
        let page = """
        <!doctype html><html><body><main>
        <div data-content-search-unit-key="fallback-turn-0:0:user"><div data-user-message-bubble="true">first question</div></div>
        <div data-content-search-unit-key="fallback-turn-0:2:assistant"><div class="MarkdownRoot-a1" data-markdown-text-style="assistant-message">old answer</div></div>
        <div data-content-search-unit-key="fallback-turn-1:0:user"><div data-user-message-bubble="true">鼻炎打针有风险吗</div></div>
        <div data-content-search-unit-key="fallback-turn-1:2:assistant">
          <div class="MarkdownRoot-a1" data-markdown-text-style="assistant-message"><p>脱敏针：有一定风险</p></div>
          <span class="source-chip">BSACI</span>
          <div class="MarkdownRoot-a1" data-markdown-text-style="assistant-message"><p>长效激素针：不推荐</p></div>
        </div>
        </main></body></html>
        """
        let web = try await load(page, host: "chatgpt.com")
        let text = try await web.evaluateJavaScript(Broadcaster.extractAnswerScript()) as? String
        XCTAssertEqual(text, "脱敏针：有一定风险\n\n长效激素针：不推荐")
    }

    /// The pre-2026 markup still reads, in case a region or an account gets the old UI.
    func testExtractsChatGPTAnswerFromTheOldMarkup() async throws {
        let page = """
        <!doctype html><html><body><main>
        <div data-message-author-role="user">q</div>
        <div data-message-author-role="assistant"><div class="markdown">the answer</div></div>
        </main></body></html>
        """
        let web = try await load(page, host: "chatgpt.com")
        let text = try await web.evaluateJavaScript(Broadcaster.extractAnswerScript()) as? String
        XCTAssertEqual(text, "the answer")
    }

    // MARK: DeepSeek answers with code

    /// A DeepSeek answer whose code block keeps streaming under a finished paragraph. The
    /// paragraph carries a "markdown" class, the code block doesn't — so measuring only the last
    /// "markdown" element saw nothing change and declared the answer done mid-code (~14 s in).
    /// Measuring the whole message sees the code grow.
    func testDeepSeekCodeStreamingUnderAStillParagraphIsNotDone() async throws {
        let page = """
        <!doctype html><html><body>
        <div class="ds-virtual-list"><div class="ds-virtual-list-items" id="chat"></div></div>
        <textarea></textarea>
        <div role="button" class="ds-button ds-button--primary ds-button--circle">↑</div>
        <script>
        document.querySelector('[role=button]').addEventListener('click', () => {
          const ta = document.querySelector('textarea');
          if (!ta.value.trim()) return;
          ta.value = '';
          const m = document.createElement('div'); m.className = 'ds-message';
          m.innerHTML = '<div class="ds-markdown ds-assistant-message-main-content"><p class="ds-markdown-paragraph">Here is the code:</p><div class="md-code-block"><pre></pre></div></div>';
          document.getElementById('chat').appendChild(m);
          const pre = m.querySelector('pre');
          let n = 0;
          const t = setInterval(() => { pre.textContent += 'line ' + (++n) + '\\n'; if (n === 20) clearInterval(t); }, 1000);
        });
        window.__fakeReady = true;
        </script></body></html>
        """
        let (sink, _) = try await send(page: page, host: "chat.deepseek.com", seconds: 16.5, until: { _ in false })
        XCTAssertTrue(sink.logs.contains { $0.contains("answer already on the page at first look") },
                      "scenario didn't start the text-settle clock; logs: \(sink.logs)")
        XCTAssertTrue(sink.completions.isEmpty, "declared done while the code block was still streaming; logs: \(sink.logs)")
    }

    /// The ordinary path still works: stop button seen, then gone → done.
    func testStreamingAnswerCompletesAfterStopButtonGoes() async throws {
        let (sink, t) = try await send(page: chatgptPage(answer: "stream"), host: "chatgpt.com", seconds: 10)
        XCTAssertNotNil(t, "no completion; logs: \(sink.logs)")
        XCTAssertTrue(sink.diagnostics.contains("streaming-started"), "stop button never seen; logs: \(sink.logs)")
        if let t { XCTAssertGreaterThan(t, 2.4, "declared done while still streaming") }
    }
}
