import XCTest
@testable import Chorus

@MainActor
final class SummaryLifecycleTests: XCTestCase {
    func testQueuedOldAnswerAndThinkingCannotContaminateANewComparison() async {
        let model = SummaryModel()
        model.streaming = true
        let oldRun = model.run
        let queued = Task { @MainActor in
            model.append("old answer", for: oldRun)
            model.append("old reasoning", for: oldRun, isThinking: true)
            model.append("old error", for: oldRun)
        }
        model.reset()
        model.streaming = true
        model.append("new answer", for: model.run)
        model.append("new reasoning", for: model.run, isThinking: true)
        await queued.value
        XCTAssertEqual(model.text, "new answer")
        XCTAssertEqual(model.thinking, "new reasoning")
        XCTAssertTrue(model.streaming)
    }

    func testStopKeepsPartialResultAndRejectsQueuedUpdates() async {
        let model = SummaryModel()
        model.streaming = true
        let run = model.run
        model.append("partial", for: run)
        model.append("thought", for: run, isThinking: true)
        let queued = Task { @MainActor in
            model.append(" late answer", for: run)
            model.append(" late reasoning", for: run, isThinking: true)
        }
        model.stop()
        await queued.value
        XCTAssertEqual(model.text, "partial")
        XCTAssertEqual(model.thinking, "thought")
        XCTAssertFalse(model.streaming)
    }

    func testCurrentComparisonStillAcceptsAnswerAndThinking() {
        let model = SummaryModel()
        model.streaming = true
        model.append("think", for: model.run, isThinking: true)
        model.append("hello", for: model.run)
        model.append(" world", for: model.run)
        XCTAssertEqual(model.text, "hello world")
        XCTAssertEqual(model.thinking, "think")
    }
}
