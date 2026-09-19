import XCTest
@testable import Chorus

final class MemoryHeartbeatTests: XCTestCase {
    func testFirstSampleAlwaysReportsABaseline() {
        XCTAssertEqual(FootprintReport.decide(sampleIndex: 0, currentMB: 40, lastReportedMB: nil), .routine)
        XCTAssertEqual(FootprintReport.decide(sampleIndex: 3, currentMB: 40, lastReportedMB: nil), .routine)
    }

    func testQuietMinutesStaySilentAndEveryTenthReports() {
        XCTAssertNil(FootprintReport.decide(sampleIndex: 7, currentMB: 60, lastReportedMB: 50))
        XCTAssertEqual(FootprintReport.decide(sampleIndex: 10, currentMB: 60, lastReportedMB: 50), .routine)
    }

    func testAJumpReportsImmediatelyWithItsSize() {
        XCTAssertEqual(FootprintReport.decide(sampleIndex: 7, currentMB: 320, lastReportedMB: 50), .growth(deltaMB: 270))
        XCTAssertNil(FootprintReport.decide(sampleIndex: 7, currentMB: 299, lastReportedMB: 50))   // just under the step
        // Growth outranks the routine slot, so the line carries the trail.
        XCTAssertEqual(FootprintReport.decide(sampleIndex: 10, currentMB: 900, lastReportedMB: 50), .growth(deltaMB: 850))
    }

    func testShrinkingIsNotGrowth() {
        XCTAssertNil(FootprintReport.decide(sampleIndex: 7, currentMB: 40, lastReportedMB: 900))
    }

    func testBreadcrumbsKeepOnlyTheNewestAndOnlyTheRecent() {
        var c = Breadcrumbs(capacity: 3)
        let now = Date()
        c.note("old", at: now.addingTimeInterval(-3600))
        c.note("a", at: now.addingTimeInterval(-30))
        c.note("b", at: now.addingTimeInterval(-20))
        c.note("c", at: now.addingTimeInterval(-10))          // pushes "old" out
        XCTAssertEqual(c.items.map(\.what), ["a", "b", "c"])
        c.note("stale", at: now.addingTimeInterval(-2000))
        let recent = c.recent(within: 900, now: now)
        XCTAssertEqual(recent.count, 2)                          // "b", "c" kept; "stale" is too old
        XCTAssertTrue(recent.allSatisfy { $0.hasSuffix(" b") || $0.hasSuffix(" c") })
    }

    func testFootprintIsReadableAndPlausible() throws {
        let mb = try XCTUnwrap(MemoryHeartbeat.footprintMB())
        XCTAssertTrue((1...100_000).contains(mb), "implausible footprint: \(mb) MB")
    }
}
