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
    /// is evaluated right after it, before sending.
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
            if let focusCheck { checked?(try await web.evaluateJavaScript(focusCheck)) }
        }
        let start = Date()
        web.evaluateJavaScript(Broadcaster.injectionScript(text: text), completionHandler: nil)
        while Date().timeIntervalSince(start) < seconds {
            if done(sink) { return (sink, Date().timeIntervalSince(start)) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return (sink, nil)
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
    private func chatgptPage(answer: String, shell: Bool = false) -> String {
        let composer = """
        <div id="prompt-textarea" contenteditable="true"></div>
        <button data-testid="send-button">send</button>
        """
        let body = shell ? """
        <aside data-app-shell-left-panel-appearance="default">chat history</aside>
        <nav data-app-navigation-rail="true">rail</nav>
        <header data-app-shell-titlebar="true" style="position:fixed;top:0;height:52px">ChatGPT 5 ▾</header>
        <div data-app-shell-thread-edge-divider="false" style="margin-top:52px">
          <div id="chat"><div class="markdown">an earlier answer</div></div>
          <div data-markdown-copy="exclude" class="text-center text-xs">ChatGPT can make mistakes.</div>
        </div>
        <div data-thread-scroll-footer="true"><form data-chatgpt-composer="" onsubmit="event.preventDefault()">\(composer)</form></div>
        """ : """
        <div id="chat"><div class="markdown">an earlier answer</div></div>
        \(composer)
        """
        return """
        <!doctype html><html><body><main data-app-shell-main-surface="browser" style="border-left:0.5px solid #ccc">
        \(body)
        </main>
        <script>
        document.querySelector('[data-testid=send-button]').addEventListener('click', () => {
          const ed = document.getElementById('prompt-textarea');
          if (!ed.innerText.trim()) return;
          ed.innerHTML = '';
          const mode = '\(answer)';
          if (mode === 'none') return;
          const d = document.createElement('div'); d.className = 'markdown';
          document.getElementById('chat').appendChild(d);
          if (mode === 'instant') { d.textContent = '糯米 团子 小满'; return; }
          const stop = document.createElement('button'); stop.setAttribute('data-testid', 'stop-button'); stop.textContent = '■';
          (document.querySelector('form') || document.querySelector('main')).appendChild(stop);
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
        let (sink, t) = try await send(page: deepseekPage(answer: "instant"), host: "chat.deepseek.com", seconds: 6) { s in
            s.logs.contains { $0.contains("answer already on the page at first look") }
        }
        XCTAssertNotNil(t, "first look didn't notice the finished answer; logs: \(sink.logs)")
    }

    func testDeepSeekNothingAnsweredIsNotMistakenForDone() async throws {
        let (sink, t) = try await send(page: deepseekPage(answer: "none"), host: "chat.deepseek.com", seconds: 5) { s in
            s.logs.contains { $0.contains("answer already on the page") } || !s.completions.isEmpty
        }
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
    /// the box is made transparent and click-through rather than display:none.
    func testFocusModeHidesChatGPTChromeButSendAndStopStillWork() async throws {
        var styles: [String: String] = [:]
        let check = """
        JSON.stringify({ composer: getComputedStyle(document.querySelector('form')).opacity,
                         clicks: getComputedStyle(document.querySelector('#prompt-textarea')).pointerEvents,
                         header: getComputedStyle(document.querySelector('header')).display,
                         sidebar: getComputedStyle(document.querySelector('aside')).display,
                         rail: getComputedStyle(document.querySelector('nav')).display,
                         border: getComputedStyle(document.querySelector('main')).borderLeftWidth,
                         frameTop: getComputedStyle(document.querySelector('[data-app-shell-thread-edge-divider]')).marginTop,
                         disclaimer: getComputedStyle(document.querySelector('[data-markdown-copy]')).display })
        """
        let (sink, t) = try await send(page: chatgptPage(answer: "stream", shell: true), host: "chatgpt.com", seconds: 10,
                                       focus: true, focusCheck: check) { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }
        XCTAssertEqual(styles, ["composer": "0", "clicks": "none", "header": "none", "sidebar": "none", "rail": "none",
                                "border": "0px", "frameTop": "0px", "disclaimer": "none"])
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
                         sidebar: getComputedStyle(document.querySelector('.dc04ec1d')).display,
                         main: getComputedStyle(document.querySelector('._7780f2e')).display,
                         composer: getComputedStyle(document.querySelector('._871cbca')).opacity,
                         clicks: getComputedStyle(document.querySelector('[role=button]')).pointerEvents,
                         answers: getComputedStyle(document.querySelector('.ds-virtual-list-items')).opacity })
        """
        let (sink, t) = try await send(page: deepseekPage(answer: "instant", shell: true), host: "chat.deepseek.com", seconds: 6,
                                       focus: true, focusCheck: check, checked: { v in
            styles = (try? JSONSerialization.jsonObject(with: Data(((v as? String) ?? "{}").utf8))) as? [String: String] ?? [:]
        }) { s in
            s.logs.contains { $0.contains("answer already on the page at first look") }
        }
        XCTAssertEqual(styles, ["header": "none", "sidebar": "none", "main": "block", "composer": "0", "clicks": "none", "answers": "1"])
        XCTAssertNotNil(t, "first look didn't notice the answer under focus mode; logs: \(sink.logs)")
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

    /// The ordinary path still works: stop button seen, then gone → done.
    func testStreamingAnswerCompletesAfterStopButtonGoes() async throws {
        let (sink, t) = try await send(page: chatgptPage(answer: "stream"), host: "chatgpt.com", seconds: 10)
        XCTAssertNotNil(t, "no completion; logs: \(sink.logs)")
        XCTAssertTrue(sink.diagnostics.contains("streaming-started"), "stop button never seen; logs: \(sink.logs)")
        if let t { XCTAssertGreaterThan(t, 2.4, "declared done while still streaming") }
    }
}
