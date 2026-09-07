import XCTest
@testable import Chorus

/// `chipsAreChinese(for:)` decides the language of content-facing text — the quick-prompt chips
/// and, since 0.2.6, the summary instruction — from the INPUT rather than the UI setting.
final class LanguageHeuristicTests: XCTestCase {
    func testChineseQuestionIsChinese() {
        XCTAssertTrue(chipsAreChinese(for: "人类证明和机器验证区别是什么"))
    }

    func testEnglishQuestionIsEnglish() {
        XCTAssertFalse(chipsAreChinese(for: "What is the difference between human proof and machine verification?"))
    }

    func testChineseSentenceWithEnglishTermsStaysChinese() {
        // One Chinese character carries the weight of a word, so a Chinese sentence quoting
        // English jargon still reads as Chinese even though the Latin letter count is higher.
        XCTAssertTrue(chipsAreChinese(for: "解释一下 transformer 的 attention 机制"))
    }

    func testEnglishProseWithOneStrayCharacterStaysEnglish() {
        XCTAssertFalse(chipsAreChinese(for: "Summarize the 3 answers about Lean 4 and Coq please, thanks 谢"))
    }
}
