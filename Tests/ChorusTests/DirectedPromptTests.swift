import XCTest
@testable import Chorus

final class DirectedPromptTests: XCTestCase {
    /// A typical on-screen set: three built-ins plus a web DeepSeek AND an API DeepSeek that
    /// share a display name (the case that makes exact-match multi-target necessary).
    private let panels: [DirectedPrompt.Candidate] = [
        .init(id: "chatgpt", name: "ChatGPT"),
        .init(id: "claude", name: "Claude"),
        .init(id: "gemini", name: "Gemini"),
        .init(id: "x_chat_deepseek_com", name: "DeepSeek"),
        .init(id: "api_deepseek", name: "DeepSeek"),
    ]

    private func resolve(_ s: String) -> (targets: Set<String>?, text: String) {
        DirectedPrompt.resolve(s, candidates: panels)
    }

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
}
