import Foundation

/// One completed search depth: every expected principal variation, all at the same depth.
public struct EngineSnapshot: Sendable, Equatable {
    public var depth: Int
    /// Nodes searched when the primary line was reported (0 when the engine did not say).
    public var nodes: Int
    public var nps: Int?
    /// Lines in engine MultiPV order (index 0 is `multipv 1`).
    public var pvs: [UCIInfo]

    /// Lines best-first from the side to move's point of view (the engine's own scores are already side-to-move relative).
    /// The sort is stable, so equal scores keep the engine's order.
    public var ranked: [UCIInfo] {
        func key(_ i: UCIInfo) -> (Double, Int) {
            let e = i.eval(whiteToMove: true) ?? .cp(0)
            return (e.whiteWinPercent, e.centipawns)
        }
        return pvs.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            if ka.0 != kb.0 { return ka.0 > kb.0 }
            if ka.1 != kb.1 { return ka.1 > kb.1 }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// Turns the raw stream of UCI `info` lines into one snapshot per completed depth (lichess-style):
/// a depth is published only once all of its MultiPV lines have arrived, so lines never mix depths.
public struct SnapshotAccumulator: Sendable {
    /// How many PVs a complete depth carries: min(MultiPV, legal moves), lowered if the engine proves to send fewer.
    public private(set) var expectedPVs: Int
    private var pending: [Int: UCIInfo] = [:]
    private var pendingDepth: Int?
    private var lastPrimaryDepth: Int?

    public init(expectedPVs: Int) { self.expectedPVs = max(1, expectedPVs) }

    /// Feeds one parsed `info` line. Returns a snapshot when it completes a depth.
    public mutating func accumulate(_ info: UCIInfo) -> EngineSnapshot? {
        guard info.hasScore, !info.pv.isEmpty, info.multipv >= 1 else { return nil }

        if info.multipv == 1 {
            // A bound on the primary line is not a result; the exact score follows at the same depth.
            if info.isBound { return nil }
            // Only the next depth starts a new snapshot; skipped or repeated depths are ignored.
            if let last = lastPrimaryDepth, info.depth != last + 1 { return nil }
            // The previous depth never completed: the engine sends fewer PVs than expected. Learn that.
            if pendingDepth != nil, !pending.isEmpty, pending.count < expectedPVs {
                let contiguous = (1...pending.count).allSatisfy { pending[$0] != nil }
                if contiguous { expectedPVs = pending.count }
            }
            lastPrimaryDepth = info.depth
            pendingDepth = info.depth
            pending = [1: info]
        } else {
            // Secondary lines only count for the depth currently being collected.
            guard pendingDepth == info.depth else { return nil }
            if info.multipv > expectedPVs { expectedPVs = info.multipv }
            pending[info.multipv] = info
        }

        guard pending.count >= expectedPVs, (1...expectedPVs).allSatisfy({ pending[$0] != nil }) else { return nil }
        let pvs = (1...expectedPVs).compactMap { pending[$0] }
        let depth = pvs.map(\.depth).min() ?? info.depth
        let snap = EngineSnapshot(depth: depth, nodes: pvs[0].nodes ?? 0, nps: pvs[0].nps ?? info.nps, pvs: pvs)
        pending = [:]
        pendingDepth = nil
        return snap
    }
}
