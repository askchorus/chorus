import Foundation

/// Which panels a layout preset ("show 1/2/3/4/6 AIs") shows.
///
/// The picker used to show the first N panels in panel order, which threw away the user's own
/// pick: showing Gemini, ChatGPT and DeepSeek with Claude hidden, then trying 6 and going back to
/// 3, left Claude, Gemini and ChatGPT on screen. Now the panels the user chose themselves are the
/// selection: a larger preset adds the next panels in order on top of it, a smaller one keeps
/// the first of it, and going back restores it. The selection is taken afresh from what's on
/// screen whenever that no longer matches what the last preset produced — i.e. the user has shown,
/// hidden, added or removed a panel since.
enum LayoutSelection {
    /// - Parameters:
    ///   - all: every panel key in panel order.
    ///   - visible: the keys showing now.
    ///   - selection: the remembered pick (may be stale or empty).
    ///   - lastPreset: the keys the previous preset left showing (empty if none yet).
    /// - Returns: the keys to show, in panel order, and the pick to remember.
    static func apply(count: Int, all: [String], visible: Set<String>, selection: [String],
                      lastPreset: Set<String>) -> (show: [String], selection: [String]) {
        let changedByHand = lastPreset.isEmpty || lastPreset != visible
        let base = changedByHand ? visible : Set(selection)
        let pick = all.filter { base.contains($0) }            // panel order, gone keys dropped
        let chosen = pick.isEmpty ? all.filter(visible.contains) : pick
        let show: [String]
        if count <= chosen.count {
            let keep = Set(chosen.prefix(count))
            show = all.filter(keep.contains)
        } else {
            let extra = all.filter { !chosen.contains($0) }.prefix(count - chosen.count)
            let keep = Set(chosen).union(extra)
            show = all.filter(keep.contains)
        }
        return (show, chosen)
    }
}
