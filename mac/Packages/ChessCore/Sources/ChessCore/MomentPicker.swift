import Foundation

extension Position {
    /// Material of `side` in pawns (N/B 3, R 5, Q 9; kings not counted).
    public func material(_ side: Side) -> Int {
        board.reduce(0) { n, p in
            guard let p, p.color == side, p.type != .king else { return n }
            return n + p.type.value
        }
    }

    func balance(_ side: Side) -> Int { material(side) - material(side.opposite) }

    /// Material `played` gives up, judged along the engine's continuation `reply` (UCI, from the position after it):
    /// the balance must drop by 2+ after the opponent's reply and still be down 1+ after up to two more plies,
    /// so an ordinary exchange that the mover wins back at once is not a sacrifice. 0 when nothing is given up.
    public func sacrifice(played: Move, reply: [String]) -> Int {
        guard let mover = board[played.from]?.color, isLegal(played) else { return 0 }
        let base = balance(mover)
        var pos = applyingUnchecked(played)
        var lossAfterReply: Int?
        var lossAtEnd = base - pos.balance(mover)
        for (i, u) in reply.prefix(3).enumerated() {
            guard let m = pos.move(fromUCI: u) else { break }
            pos = pos.applyingUnchecked(m)
            lossAtEnd = base - pos.balance(mover)
            if i == 0 { lossAfterReply = lossAtEnd }
        }
        guard let l2 = lossAfterReply, l2 >= 2, lossAtEnd >= 1 else { return 0 }
        return max(l2, lossAtEnd)
    }
}

/// One reviewed move, for `MomentPicker`.
public struct PlyReview: Sendable, Equatable {
    public var index: Int           // position in the reviewed line (1 = first move)
    public var mover: Side
    public var evalBefore: Eval     // White's view
    public var evalAfter: Eval
    public var loss: Double         // win-probability points lost by the mover
    public var severity: Int        // 0 none, 1 inaccuracy, 2 mistake, 3 blunder
    public var positive: Int        // 0 none, 1 great, 2 brilliant

    public init(index: Int, mover: Side, evalBefore: Eval, evalAfter: Eval, loss: Double, severity: Int, positive: Int = 0) {
        self.index = index; self.mover = mover; self.evalBefore = evalBefore; self.evalAfter = evalAfter
        self.loss = loss; self.severity = severity; self.positive = positive
    }
}

public struct PickedMoment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case error(Int), great, brilliant, turningPoint }
    public var index: Int
    public var kind: Kind
    public var score: Double
}

/// Chooses the moments worth studying from the engine's evaluations alone, for both sides:
/// - errors (inaccuracy / mistake / blunder by win-probability loss);
/// - strong moves: engine-approved sacrifices ("!" / "!!", see `Position.sacrifice`). The review runs MultiPV 1, so
///   "only moves" (where the second-best move is much worse) can't be detected and aren't;
/// - turning points: the evaluation crosses a band (equal, advantage at 0.7, winning at 2.0 or mate), or swings by a
///   pawn or more while the game is still within 5 pawns, even when win probability barely moves.
/// Returns at most `limit` moments in game order. A turning point right next to an error or strong move is dropped
/// (that move already explains it), and of two adjacent turning points only the bigger one stays.
public enum MomentPicker {
    public static let advantage = 70, winning = 200, swing = 100, swingCeiling = 500

    /// -2...2: Black winning, Black better, equal, White better, White winning.
    public static func band(_ e: Eval) -> Int {
        switch e {
        case .mate(let m): return m > 0 ? 2 : -2
        case .checkmate(let w): return w == .white ? 2 : -2
        case .cp(let c):
            if c >= winning { return 2 }
            if c >= advantage { return 1 }
            if c <= -winning { return -2 }
            if c <= -advantage { return -1 }
            return 0
        }
    }

    public static func pick(_ plies: [PlyReview], limit: Int = 8) -> [PickedMoment] {
        var cands: [PickedMoment] = []
        for p in plies {
            if p.severity > 0 {
                let base: Double = p.severity == 3 ? 100 : p.severity == 2 ? 60 : 20
                cands.append(PickedMoment(index: p.index, kind: .error(p.severity), score: base + p.loss))
            } else if p.positive > 0 {
                cands.append(PickedMoment(index: p.index, kind: p.positive >= 2 ? .brilliant : .great, score: p.positive >= 2 ? 90 : 70))
            } else {
                let db = abs(band(p.evalAfter) - band(p.evalBefore))
                let b = p.evalBefore.centipawns, a = p.evalAfter.centipawns
                let swung = abs(a - b) >= swing && min(abs(a), abs(b)) < swingCeiling
                if db > 0 || swung {
                    let score = db > 0 ? 40 + Double(db) * 10 : 10 + Double(abs(a - b)) / 100
                    cands.append(PickedMoment(index: p.index, kind: .turningPoint, score: score))
                }
            }
        }
        // Merge: a turning point beside a classified move is that move's consequence.
        let classified = Set(cands.filter { $0.kind != .turningPoint }.map(\.index))
        cands.removeAll { $0.kind == .turningPoint && (classified.contains($0.index - 1) || classified.contains($0.index + 1)) }
        var merged: [PickedMoment] = []
        for c in cands.sorted(by: { $0.index < $1.index }) {
            if c.kind == .turningPoint, let last = merged.last, last.kind == .turningPoint, c.index - last.index <= 1 {
                if c.score > last.score { merged[merged.count - 1] = c }
                continue
            }
            merged.append(c)
        }
        return merged.sorted { $0.score > $1.score }.prefix(limit).sorted { $0.index < $1.index }
    }
}
