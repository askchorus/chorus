import XCTest
@testable import Chorus

final class SleepGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func hold(_ pending: Int, since: TimeInterval? = nil, cappedOut: Bool = false) -> Bool {
        SleepGuardPolicy.shouldHold(pendingBatches: pending,
                                    holdingSince: since.map { t0.addingTimeInterval(-$0) },
                                    cappedOut: cappedOut, now: t0)
    }

    func testAnIdleAppLetsTheMacSleep() {
        XCTAssertFalse(hold(0))
        XCTAssertFalse(hold(0, since: 30))   // a hold in place but nothing pending: let it go
    }

    func testAPendingBroadcastHoldsSleepOff() {
        XCTAssertTrue(hold(1))
        XCTAssertTrue(hold(2, since: 60))
    }

    func testALongThinkingRunStillHoldsUpToTheCeiling() {
        XCTAssertTrue(hold(1, since: SleepGuardPolicy.maxHold - 1))
    }

    func testAStuckBatchStopsHoldingAtTheCeiling() {
        XCTAssertFalse(hold(1, since: SleepGuardPolicy.maxHold))
        XCTAssertFalse(hold(1, since: 10 * 3600))
    }

    func testOnceCappedItDoesNotReacquireWhileStillPending() {
        XCTAssertFalse(hold(1, cappedOut: true))
        XCTAssertFalse(hold(1, since: 5, cappedOut: true))
    }
}
