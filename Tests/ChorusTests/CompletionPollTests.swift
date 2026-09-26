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
    private func send(page: String, host: String, text: String = "三个名字", seconds: TimeInterval,
                      until done: @escaping (Sink) -> Bool = { !$0.completions.isEmpty }) async throws -> (Sink, TimeInterval?) {
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
    private func deepseekPage(answer: String) -> String {
        """
        <!doctype html><html><body>
        <div id="chat"></div>
        <textarea></textarea>
        <div role="button" class="ds-button ds-button--primary ds-button--circle">↑</div>
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
    // already on the page. "instant" answers at once; "stream" shows the stop button and grows
    // the answer for ~2.4s; "none" answers nothing.
    private func chatgptPage(answer: String) -> String {
        """
        <!doctype html><html><body><main>
        <div id="chat"><div class="markdown">an earlier answer</div></div>
        <div id="prompt-textarea" contenteditable="true"></div>
        <button data-testid="send-button">send</button>
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
          document.querySelector('main').appendChild(stop);
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

    /// The ordinary path still works: stop button seen, then gone → done.
    func testStreamingAnswerCompletesAfterStopButtonGoes() async throws {
        let (sink, t) = try await send(page: chatgptPage(answer: "stream"), host: "chatgpt.com", seconds: 10)
        XCTAssertNotNil(t, "no completion; logs: \(sink.logs)")
        XCTAssertTrue(sink.diagnostics.contains("streaming-started"), "stop button never seen; logs: \(sink.logs)")
        if let t { XCTAssertGreaterThan(t, 2.4, "declared done while still streaming") }
    }
}
