import Foundation

/// When the Mac should be kept from idle-sleeping. Pure, so the rule is unit-tested.
enum SleepGuardPolicy {
    /// Ceiling on a single hold. The page-side completion poll gives up after 15 minutes; past
    /// that the batch is stuck, and a stuck batch must not keep the machine awake for days.
    static let maxHold: TimeInterval = 20 * 60

    /// `cappedOut` latches once a hold has hit the ceiling, so the same stuck batch can't be
    /// re-acquired on the next tick; it clears when nothing is pending any more.
    static func shouldHold(pendingBatches: Int, holdingSince: Date?, cappedOut: Bool, now: Date) -> Bool {
        guard pendingBatches > 0, !cappedOut else { return false }
        guard let since = holdingSince else { return true }
        return now.timeIntervalSince(since) < maxHold
    }
}

/// Keeps the Mac awake while a broadcast is still being answered — and only then.
///
/// Chorus used to hold `NSActivityUserInitiated` for its entire lifetime, and that option carries
/// `IdleSystemSleepDisabled`: the Mac could not idle-sleep for as long as the app was open (found
/// holding it for 62 hours straight). App Nap avoidance, the reason that activity exists, is
/// equally served by `userInitiatedAllowingIdleSystemSleep`. Sleep is now blocked only for the
/// minutes an answer is actually in flight, so "send, walk away, get notified" still works.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()

    private var token: NSObjectProtocol?
    private var holdingSince: Date?
    private var cappedOut = false

    var isHolding: Bool { token != nil }

    func sync(pendingBatches: Int, now: Date = Date()) {
        if pendingBatches == 0 { cappedOut = false }
        let want = SleepGuardPolicy.shouldHold(pendingBatches: pendingBatches,
                                               holdingSince: holdingSince,
                                               cappedOut: cappedOut, now: now)
        if want, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                          reason: "Waiting for AI answers")
            holdingSince = now
            clog("[Power] holding off idle sleep while \(pendingBatches) broadcast(s) finish")
        } else if !want, let t = token {
            ProcessInfo.processInfo.endActivity(t)
            let held = holdingSince.map { Int(now.timeIntervalSince($0)) } ?? 0
            token = nil
            holdingSince = nil
            if pendingBatches > 0 {
                cappedOut = true
                clog("[Power] released the sleep hold after \(held)s — \(pendingBatches) batch(es) still pending, letting the Mac sleep anyway")
            } else {
                clog("[Power] released the sleep hold after \(held)s")
            }
        }
    }
}
