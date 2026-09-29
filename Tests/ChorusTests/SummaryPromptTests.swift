import XCTest
@testable import Chorus

/// The comparison prompt: answers go to the model under [A], [B]… with no AI names, the model is
/// asked to judge rather than restate, and the sheet shows the result with the names put back.
final class SummaryPromptTests: XCTestCase {
    private let answers: [(name: String, text: String)] = [
        ("ChatGPT", "Mochi is a soft, sweet name."),
        ("Claude", "Biscuit fits a small, warm cat."),
        ("Gemini", "Sir Pounce, for a cat that pounces."),
    ]

    func testAnswersGoInUnderLabelsWithoutNames() {
        let built = SummaryPrompt.build(question: "What should I name my kitten?", answers: answers, chinese: false)
        XCTAssertEqual(built.names, ["[A]": "ChatGPT", "[B]": "Claude", "[C]": "Gemini"])
        XCTAssertTrue(built.prompt.contains("[A]\nMochi is a soft, sweet name."))
        XCTAssertTrue(built.prompt.contains("[C]\nSir Pounce, for a cat that pounces."))
        XCTAssertTrue(built.prompt.contains("labeled [A], [B], [C]"))
        for name in ["ChatGPT", "Claude", "Gemini"] {
            XCTAssertFalse(built.prompt.contains(name), "\(name) leaked into the prompt")
        }
        XCTAssertTrue(built.prompt.contains("the question “What should I name my kitten?”"))
    }

    func testBothLanguagesLeadWithTheAnswerAndCarryTheRules() {
        let en = SummaryPrompt.build(question: "Q", answers: answers, chinese: false).prompt
        let zh = SummaryPrompt.build(question: "问题", answers: answers, chinese: true).prompt
        // The best answer comes first, before the agreement/disagreement sections.
        XCTAssertLessThan(en.range(of: "**Bottom line**")!.lowerBound, en.range(of: "**Where they differ**")!.lowerBound)
        XCTAssertLessThan(zh.range(of: "**结论**")!.lowerBound, zh.range(of: "**分歧与判断**")!.lowerBound)
        for (prompt, phrases) in [(en, ["don't favor any answer", "which is more likely right", "refuses, errors out",
                                        "no single right answer", "Do not use markdown tables"]),
                                  (zh, ["不要偏袒任何一份", "谁更可能对", "拒答、报错", "没有标准答案", "不要用 markdown 表格"])] {
            for p in phrases { XCTAssertTrue(prompt.contains(p), "missing: \(p)") }
        }
        XCTAssertTrue(zh.contains("分别标为 [A]、[B]、[C]"))
        XCTAssertTrue(SummaryPrompt.build(question: "", answers: answers, chinese: false).prompt.contains("to the same question"))
    }

    func testRevealPutsTheNamesBack() {
        let names = SummaryPrompt.build(question: "Q", answers: answers, chinese: false).names
        XCTAssertEqual(SummaryPrompt.reveal("[A] and [B] agree; [C] goes its own way.", names: names),
                       "ChatGPT and Claude agree; Gemini goes its own way.")
        // Full-width brackets, as a model writing Chinese often uses them.
        XCTAssertEqual(SummaryPrompt.reveal("［A］和【C】都认为", names: names), "ChatGPT和Gemini都认为")
        // Other brackets are left alone, and so is everything before the names are known.
        XCTAssertEqual(SummaryPrompt.reveal("[x] a checkbox, [D] no such answer", names: names), "[x] a checkbox, [D] no such answer")
        XCTAssertEqual(SummaryPrompt.reveal("[A] says", names: [:]), "[A] says")
    }

    func testLabelsPastZStayUnique() {
        XCTAssertEqual(SummaryPrompt.label(0), "[A]")
        XCTAssertEqual(SummaryPrompt.label(25), "[Z]")
        XCTAssertEqual(SummaryPrompt.label(26), "[27]")
    }

    /// The viewer parses inline markdown only; "## Heading" lines come out bold instead of with
    /// their hashes.
    func testHeadingsRenderBold() {
        XCTAssertEqual(MarkdownText.headingsAsBold("## Bottom line\ntext\n### Where they differ"),
                       "**Bottom line**\ntext\n**Where they differ**")
        XCTAssertEqual(MarkdownText.headingsAsBold("#hashtag and C# stay\n##"), "#hashtag and C# stay\n##")
    }
}
