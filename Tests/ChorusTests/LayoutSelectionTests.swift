import XCTest
@testable import Chorus

/// Layout presets keep the panels the user picked instead of resetting to the first N in order.
final class LayoutSelectionTests: XCTestCase {
    // The user's order: Claude first, but they show Gemini, ChatGPT and DeepSeek.
    let all = ["claude", "gemini", "chatgpt", "doubao", "grok", "kimi", "deepseek", "manus"]
    let mine: Set<String> = ["gemini", "chatgpt", "deepseek"]

    /// The reported bug: 3 → 6 → 3 came back as Claude, Gemini, ChatGPT.
    func testGoingUpAndBackRestoresThePick() {
        let six = LayoutSelection.apply(count: 6, all: all, visible: mine, selection: [], lastPreset: [])
        XCTAssertEqual(six.show, ["claude", "gemini", "chatgpt", "doubao", "grok", "deepseek"])
        XCTAssertEqual(six.selection, ["gemini", "chatgpt", "deepseek"])
        let three = LayoutSelection.apply(count: 3, all: all, visible: Set(six.show), selection: six.selection,
                                          lastPreset: Set(six.show))
        XCTAssertEqual(three.show, ["gemini", "chatgpt", "deepseek"])
    }

    func testGoingDownAndBackRestoresThePick() {
        let one = LayoutSelection.apply(count: 1, all: all, visible: mine, selection: [], lastPreset: [])
        XCTAssertEqual(one.show, ["gemini"])
        let three = LayoutSelection.apply(count: 3, all: all, visible: Set(one.show), selection: one.selection,
                                          lastPreset: Set(one.show))
        XCTAssertEqual(three.show, ["gemini", "chatgpt", "deepseek"])
    }

    /// Showing or hiding a panel by hand after a preset makes what's on screen the new pick.
    func testAHandChangeBecomesTheNewPick() {
        let six = LayoutSelection.apply(count: 6, all: all, visible: mine, selection: [], lastPreset: [])
        var nowShowing = Set(six.show); nowShowing.remove("deepseek"); nowShowing.remove("grok")   // two ✕ clicks
        let three = LayoutSelection.apply(count: 3, all: all, visible: nowShowing, selection: six.selection,
                                          lastPreset: Set(six.show))
        XCTAssertEqual(three.selection, ["claude", "gemini", "chatgpt", "doubao"])
        XCTAssertEqual(three.show, ["claude", "gemini", "chatgpt"])
    }

    func testMoreThanThereAreShowsEverything() {
        let r = LayoutSelection.apply(count: 20, all: all, visible: mine, selection: [], lastPreset: [])
        XCTAssertEqual(r.show, all)
    }

    /// A remembered panel that no longer exists (removed in Settings) is simply skipped.
    func testRemovedPanelsDropOutOfThePick() {
        let r = LayoutSelection.apply(count: 3, all: all.filter { $0 != "deepseek" }, visible: ["gemini", "chatgpt", "claude"],
                                      selection: ["gemini", "chatgpt", "deepseek"], lastPreset: ["gemini", "chatgpt", "claude"])
        XCTAssertEqual(r.show, ["claude", "gemini", "chatgpt"])
        XCTAssertEqual(r.selection, ["gemini", "chatgpt"])
    }
}
