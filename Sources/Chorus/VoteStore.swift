import Foundation
import Combine

/// Per-round "which AI won this question" votes, stored locally (append-only JSONL at
/// ~/Library/Application Support/Chorus/votes.jsonl). One immutable row per broadcast ROUND — so
/// stats are WIN RATE (wins ÷ rounds where the panel was a contender), not raw counts that an AI
/// which simply appears more often would inflate. Local-only: nothing ever leaves the machine.
///
/// The current round's pick is held in memory and committed to disk when the NEXT broadcast starts
/// (or on quit) — clicking a different panel just moves the pick, so each round writes one row.
@MainActor
final class VoteStore: ObservableObject {
    static let shared = VoteStore()

    /// Crowned winner for the CURRENT round (drives the star in the panel headers).
    @Published private(set) var currentWinner: String? = nil

    private var pending: RoundVote? = nil

    struct RoundVote: Codable {
        var v = 1
        let id: String
        let ts: String                 // ISO-8601 with timezone
        let broadcastId: String
        let question: String
        var contenders: [String]       // stable provider keys that answered this round
        var winner: String?            // provider key, or nil if skipped/undecided
        var skipped: Bool
        var names: [String: String]    // key → display name at vote time (readable exports)
    }

    // MARK: Capture

    /// A new broadcast started — commit the previous round's pick (if any), then reset.
    func newRound() {
        commitPending()
        currentWinner = nil
    }

    /// Crown `key` as this round's winner. Clicking the current winner again clears it. Round
    /// context is snapshotted here so it survives the next broadcast clearing `answeredLastBroadcast`.
    func pick(winner key: String, broadcastId: String, question: String, contenders: [String], names: [String: String]) {
        if pending?.broadcastId != broadcastId {
            pending = RoundVote(id: UUID().uuidString, ts: Self.now(), broadcastId: broadcastId,
                                question: String(question.prefix(2000)), contenders: contenders,
                                winner: nil, skipped: false, names: names)
        } else {
            // Same round, but more panels may have finished since the first pick — refresh the
            // contender set (and names) so the winner is always among the recorded contenders.
            pending?.contenders = contenders
            for (k, n) in names { pending?.names[k] = n }
        }
        if pending?.winner == key {
            pending?.winner = nil
            currentWinner = nil
        } else {
            pending?.winner = key
            currentWinner = key
        }
    }

    /// Append the pending round to disk if it carries a decision. Called on next round + on quit.
    func commitPending() {
        defer { pending = nil }
        guard let p = pending, p.winner != nil || p.skipped else { return }
        append(p)
    }

    // MARK: Read

    /// Votes for the stats view: persisted rows PLUS the current round's in-memory pick, so a
    /// just-cast vote shows up immediately (it's only written to disk on the next broadcast / quit).
    func votesForStats() -> [RoundVote] {
        var list = allVotes()
        if let p = pending, p.winner != nil { list.append(p) }
        return list
    }

    func allVotes() -> [RoundVote] {
        guard let url = Self.url, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(RoundVote.self, from: d)
        }
    }

    // MARK: Storage — append-only JSONL (a torn last line is the only possible loss)

    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let d = dir.appendingPathComponent("Chorus", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("votes.jsonl")
    }

    private func append(_ v: RoundVote) {
        guard let url = Self.url,
              let data = try? JSONEncoder().encode(v),
              let line = (String(data: data, encoding: .utf8).map { $0 + "\n" })?.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)   // first write creates the file
        }
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
