import XCTest
@testable import Chorus

/// The API panel's thinking setting: what it sends to DeepSeek and to everyone else, what a
/// comparison sends with nothing set, and how older saved panels read back.
final class ReasoningEffortTests: XCTestCase {
    private let deepseek = APIProvider(id: "api_deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-flash")
    private let openai = APIProvider(id: "api_openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-5")

    private func fields(_ p: APIProvider, _ effort: ReasoningEffort?, comparison: Bool) -> NSDictionary {
        var p = p
        p.effort = effort
        return p.reasoningFields(forComparison: comparison) as NSDictionary
    }

    func testDeepSeekTakesThinkingOnOffAndMax() {
        XCTAssertEqual(fields(deepseek, .off, comparison: false), ["thinking": ["type": "disabled"]])
        XCTAssertEqual(fields(deepseek, .low, comparison: false), ["thinking": ["type": "enabled"], "reasoning_effort": "low"])
        XCTAssertEqual(fields(deepseek, .max, comparison: true), ["thinking": ["type": "enabled"], "reasoning_effort": "max"])
    }

    func testNothingSetSendsNothingExceptAComparisonOnDeepSeek() {
        XCTAssertEqual(fields(deepseek, nil, comparison: false), [:])
        XCTAssertEqual(fields(deepseek, nil, comparison: true), ["thinking": ["type": "enabled"], "reasoning_effort": "low"])
        XCTAssertEqual(fields(openai, nil, comparison: true), [:])   // not known to take it: leave it alone
    }

    func testOthersGetReasoningEffortWithoutMax() {
        XCTAssertEqual(fields(openai, .off, comparison: false), ["reasoning_effort": "none"])
        XCTAssertEqual(fields(openai, .high, comparison: false), ["reasoning_effort": "high"])
        XCTAssertEqual(fields(openai, .max, comparison: false), ["reasoning_effort": "high"])
    }

    func testOffIsStoredAndSentAsNone() {
        XCTAssertEqual(ReasoningEffort.off.rawValue, "none")
        XCTAssertEqual(ReasoningEffort(rawValue: "none"), .off)
    }

    func testPanelsSavedBeforeTheSettingReadAsDefault() {
        let old = #"[{"id":"api_deepseek","name":"DeepSeek","baseURL":"https://api.deepseek.com/v1","model":"deepseek-reasoner"}]"#
        XCTAssertNil(APIProviderRegistry.decode(old).first?.effort)
        var p = deepseek
        p.effort = .high
        let data = try! JSONEncoder().encode([p])
        XCTAssertEqual(APIProviderRegistry.decode(String(data: data, encoding: .utf8)!).first?.effort, .high)
    }

    func testDeepSeekPresetUsesTheCurrentModel() {
        XCTAssertEqual(APIProviderRegistry.presets.first { $0.name == "DeepSeek" }?.model, "deepseek-flash")
    }

    func testStreamLinesSplitAnswerFromThinking() {
        XCTAssertEqual(APIClient.parse(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#), .delta(content: "Hi", reasoning: nil))
        XCTAssertEqual(APIClient.parse(#"data: {"choices":[{"delta":{"reasoning_content":"Let me see"}}]}"#),
                       .delta(content: nil, reasoning: "Let me see"))
        XCTAssertEqual(APIClient.parse(#"data: {"choices":[{"delta":{"content":"","reasoning_content":"x"}}]}"#),
                       .delta(content: nil, reasoning: "x"))
        XCTAssertEqual(APIClient.parse("data: [DONE]"), .done)
        XCTAssertEqual(APIClient.parse(": keep-alive"), .skip)
        XCTAssertEqual(APIClient.parse(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .skip)
    }

    func testAModelThatRejectsTheSettingSaysWhichKnob() {
        let msg = APIClient.friendly(APIClient.Err.http(400, "Unsupported parameter: 'reasoning_effort'"))
        XCTAssertTrue(msg.hasSuffix(L("api.err.effort")), msg)
        XCTAssertFalse(APIClient.friendly(APIClient.Err.http(400, "bad model")).contains(L("api.err.effort")))
    }

    @MainActor
    func testStopAndResetEndTheRunningComparison() {
        let m = SummaryModel()
        let first = m.run
        m.streaming = true
        m.text = "partial"
        m.task = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        let t = m.task
        m.stop()
        XCTAssertTrue(t!.isCancelled)
        XCTAssertFalse(m.streaming)
        XCTAssertEqual(m.text, "partial")        // Stop keeps what came in
        m.reset()
        XCTAssertNotEqual(m.run, first)          // a gather that comes back late is ignored
        XCTAssertEqual(m.text, "")
    }
}
