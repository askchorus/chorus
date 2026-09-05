import XCTest
@testable import Chorus

final class DirectedPromptTests: XCTestCase {
    /// A typical on-screen set: three built-ins plus a web DeepSeek AND an API DeepSeek that
    /// share a display name (the case that makes exact-match multi-target necessary).
    private let panels: [DirectedPrompt.Candidate] = [
        .init(id: "chatgpt", name: "ChatGPT", host: "chatgpt.com"),
        .init(id: "claude", name: "Claude", host: "claude.ai"),
        .init(id: "gemini", name: "Gemini", host: "gemini.google.com"),
        .init(id: "x_chat_deepseek_com", name: "DeepSeek", host: "chat.deepseek.com"),
        .init(id: "api_deepseek", name: "DeepSeek"),
    ]

    private func resolve(_ s: String) -> (targets: Set<String>?, text: String) {
        DirectedPrompt.resolve(s, candidates: panels)
    }

    // MARK: resolve — "@name question" typed straight through

    func testExactNameTargetsThatPanelAndStripsTheMention() {
        let r = resolve("@gemini 展开说说第二点")
        XCTAssertEqual(r.targets, ["gemini"])
        XCTAssertEqual(r.text, "展开说说第二点")
    }

    func testExactMatchIsCaseInsensitiveAndAlsoAcceptsTheKey() {
        XCTAssertEqual(resolve("@ChatGPT hi").targets, ["chatgpt"])
        XCTAssertEqual(resolve("@x_chat_deepseek_com hi").targets, ["x_chat_deepseek_com"])
    }

    func testExactNameSharedByTwoPanelsTargetsBoth() {
        XCTAssertEqual(resolve("@deepseek 你觉得呢").targets, ["x_chat_deepseek_com", "api_deepseek"])
    }

    func testUniquePrefixResolves() {
        XCTAssertEqual(resolve("@gem 继续").targets, ["gemini"])
    }

    func testPrefixSharedByOneNameTargetsAllOfThem() {
        XCTAssertEqual(resolve("@deep 再想想").targets, ["x_chat_deepseek_com", "api_deepseek"])
    }

    func testAmbiguousPrefixPassesThroughUntouched() {
        // "@c" could be ChatGPT or Claude — never guess, send the literal text everywhere.
        let r = resolve("@c 哪个对")
        XCTAssertNil(r.targets)
        XCTAssertEqual(r.text, "@c 哪个对")
    }

    func testBareMentionWithoutAQuestionIsNotDirected() {
        let r = resolve("@gemini")
        XCTAssertNil(r.targets)
        XCTAssertEqual(r.text, "@gemini")
    }

    func testUnknownNameIsLeftAlone() {
        let r = resolve("@nobody 问题")
        XCTAssertNil(r.targets)
        XCTAssertEqual(r.text, "@nobody 问题")
    }

    func testMentionNotAtTheStartIsPlainText() {
        let r = resolve("普通问题 @gemini 不在开头")
        XCTAssertNil(r.targets)
        XCTAssertEqual(r.text, "普通问题 @gemini 不在开头")
    }

    func testLeadingWhitespaceAndNewlinesAreTolerated() {
        let r = resolve("  \n@claude 第一句\n第二句  ")
        XCTAssertEqual(r.targets, ["claude"])
        XCTAssertEqual(r.text, "第一句\n第二句")
    }

    func testHiddenPanelsAreSimplyNotCandidates() {
        // The store filters hidden panels out before calling resolve; with Gemini absent,
        // "@gemini" must fall through rather than wake a hidden panel.
        let onScreen = panels.filter { $0.id != "gemini" }
        let r = DirectedPrompt.resolve("@gemini 在吗", candidates: onScreen)
        XCTAssertNil(r.targets)
    }

    // MARK: options — what the picker lists

    func testOptionsGroupSameNamedPanelsIntoOneRowInDisplayOrder() {
        let all = DirectedPrompt.options(panels)
        XCTAssertEqual(all.map(\.name), ["ChatGPT", "Claude", "Gemini", "DeepSeek"])
        XCTAssertEqual(all.last?.ids, ["x_chat_deepseek_com", "api_deepseek"])
        XCTAssertEqual(all.last?.key, "x_chat_deepseek_com")   // first seen supplies favicon/accent
    }

    func testOptionsFilterByPrefixCaseInsensitively() {
        XCTAssertEqual(DirectedPrompt.options(panels, query: "C").map(\.name), ["ChatGPT", "Claude"])
        XCTAssertEqual(DirectedPrompt.options(panels, query: "gem").map(\.name), ["Gemini"])
        XCTAssertTrue(DirectedPrompt.options(panels, query: "zzz").isEmpty)
    }

    func testTargetForTokenMirrorsResolveRules() {
        XCTAssertEqual(DirectedPrompt.target(for: "gem", in: panels)?.ids, ["gemini"])
        XCTAssertNil(DirectedPrompt.target(for: "c", in: panels))
        XCTAssertEqual(DirectedPrompt.target(for: "DEEPSEEK", in: panels)?.ids, ["x_chat_deepseek_com", "api_deepseek"])
        XCTAssertNil(DirectedPrompt.target(for: "", in: panels))
    }

    // MARK: pending / completed — what drives the picker and the auto-chip

    func testPendingMentionOnlyWhileTheTokenIsStillBeingTyped() {
        XCTAssertEqual(DirectedPrompt.pendingMention(in: "@"), "")
        XCTAssertEqual(DirectedPrompt.pendingMention(in: "@gem"), "gem")
        XCTAssertEqual(DirectedPrompt.pendingMention(in: "  @gem"), "gem")
        XCTAssertNil(DirectedPrompt.pendingMention(in: "@gemini "))
        XCTAssertNil(DirectedPrompt.pendingMention(in: "hello @gem"))
        XCTAssertNil(DirectedPrompt.pendingMention(in: "mail@example.com"))
        XCTAssertNil(DirectedPrompt.pendingMention(in: "@" + String(repeating: "x", count: 31)))
    }

    func testCompletedMentionFiresOnTheSpaceRightAfterTheToken() {
        XCTAssertEqual(DirectedPrompt.completedMention(previous: "@gemini", current: "@gemini "), "gemini")
        XCTAssertNil(DirectedPrompt.completedMention(previous: "@gemini", current: "@gemini x"))
        XCTAssertNil(DirectedPrompt.completedMention(previous: "@", current: "@ "))   // a bare "@" is nothing
        XCTAssertNil(DirectedPrompt.completedMention(previous: "hi", current: "hi "))
    }
}
