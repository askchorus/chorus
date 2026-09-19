import Foundation
import Darwin

/// When a footprint sample deserves a log line. Pure.
enum FootprintReport: Equatable {
    case routine
    case growth(deltaMB: Int)

    static let routineEvery = 10      // samples (= minutes)
    static let growthStepMB = 250

    static func decide(sampleIndex: Int, currentMB: Int, lastReportedMB: Int?) -> FootprintReport? {
        if let last = lastReportedMB, currentMB - last >= growthStepMB { return .growth(deltaMB: currentMB - last) }
        if lastReportedMB == nil || sampleIndex % routineEvery == 0 { return .routine }
        return nil
    }
}

/// A short trail of what the app was doing, so a memory jump can be read next to its cause.
/// Holds action TYPES and COUNTS only — never prompt or answer text.
struct Breadcrumbs {
    private(set) var items: [(at: Date, what: String)] = []
    let capacity: Int
    init(capacity: Int = 24) { self.capacity = capacity }

    mutating func note(_ what: String, at date: Date = Date()) {
        items.append((date, what))
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    func recent(within seconds: TimeInterval, now: Date = Date()) -> [String] {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return items.filter { now.timeIntervalSince($0.at) <= seconds }.map { "\(f.string(from: $0.at)) \($0.what)" }
    }
}

/// Once a minute, reads the app process's physical footprint (what Activity Monitor shows) and
/// writes it to the unified log: a routine line every ten minutes, and immediately — with the
/// recent action trail — whenever it has grown by 250 MB since the last line.
///
/// Why: the main process was once found at 8 GB after 17 hours, but eight hours of external
/// sampling afterwards showed a flat ~50 MB. Whatever did it is episodic; this makes the next
/// occurrence explain itself.  Read with:
///   log show --last 1d --predicate 'subsystem == "com.smiletalker.chorus"' | grep Chorus.Mem
@MainActor
final class MemoryHeartbeat {
    static let shared = MemoryHeartbeat()

    private var timer: Timer?
    private var sampleIndex = 0
    private var lastReportedMB: Int?
    private var crumbs = Breadcrumbs()

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 10                      // let the system coalesce it — this must cost nothing
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func note(_ what: String) { crumbs.note(what) }

    private func sample() {
        defer { sampleIndex += 1 }
        guard let mb = Self.footprintMB(),
              let report = FootprintReport.decide(sampleIndex: sampleIndex, currentMB: mb, lastReportedMB: lastReportedMB)
        else { return }
        lastReportedMB = mb
        switch report {
        case .routine:
            chorusLog.notice("[Chorus.Mem] footprint=\(mb, privacy: .public)MB")
        case .growth(let delta):
            let trail = crumbs.recent(within: 900).joined(separator: " · ")
            chorusLog.notice("[Chorus.Mem] footprint=\(mb, privacy: .public)MB ▲ +\(delta, privacy: .public)MB since last line — recent: \(trail.isEmpty ? "(nothing logged)" : trail, privacy: .public)")
        }
    }

    /// `phys_footprint` — the number Activity Monitor's Memory column reports.
    nonisolated static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}
