import Foundation

/// Opening, middlegame or endgame, for grading a game by phase.
public enum GamePhase: Int, CaseIterable, Sendable, Hashable, Comparable {
    case opening, middlegame, endgame

    public var name: String {
        switch self {
        case .opening: "Opening"
        case .middlegame: "Middlegame"
        case .endgame: "Endgame"
        }
    }

    public static func < (a: GamePhase, b: GamePhase) -> Bool { a.rawValue < b.rawValue }
}

extension Position {
    /// Knights, bishops, rooks and queens of both sides.
    public var minorsAndMajors: Int {
        board.reduce(0) { n, p in
            guard let p, p.type != .pawn, p.type != .king else { return n }
            return n + 1
        }
    }

    /// Pieces (not pawns or the king) of `side` still on its first rank.
    func backRankPieces(_ side: Side) -> Int {
        let rank = side == .white ? 0 : 7
        return (0..<8).filter { f in
            guard let p = board[Sq.make(file: f, rank: rank)] else { return false }
            return p.color == side && p.type != .pawn && p.type != .king
        }.count
    }

    /// Phase of this position on its own (see `GamePhases.classify` for the rules).
    public func phase(ply: Int) -> GamePhase {
        let pieces = minorsAndMajors
        if pieces <= GamePhases.endgamePieces { return .endgame }
        let queensOff = !board.contains { $0?.type == .queen }
        let developed = backRankPieces(.white) < GamePhases.developedBackRank
            && backRankPieces(.black) < GamePhases.developedBackRank
        if ply >= GamePhases.openingPlies || pieces <= GamePhases.openingPieces || queensOff || developed { return .middlegame }
        return .opening
    }
}

/// Deterministic phase split, close to lichess's "Divider":
/// - Endgame: at most 6 knights, bishops, rooks and queens are left on the board (both sides together).
/// - Middlegame: from ply 24 (White's 13th move), or earlier once both sides have at most 3 pieces left on
///   their back rank (development done), the queens are off, or at most 10 pieces remain.
/// - Otherwise the opening.
/// Phases only move forward: a position that looks like an opening again after a middlegame stays a middlegame.
public enum GamePhases {
    public static let endgamePieces = 6
    public static let openingPieces = 10
    public static let openingPlies = 24
    public static let developedBackRank = 4

    /// Phase of each position in a line; `plies[i]` is the ply count of `positions[i]` (0 = start of the game).
    public static func classify(_ positions: [Position], plies: [Int]) -> [GamePhase] {
        var out: [GamePhase] = []
        var floor = GamePhase.opening
        for (i, p) in positions.enumerated() {
            let ph = max(floor, p.phase(ply: i < plies.count ? plies[i] : i))
            out.append(ph)
            floor = ph
        }
        return out
    }
}

/// Accuracy of one side in one phase.
public struct PhaseStat: Equatable, Sendable {
    public var moves = 0
    public var accuracy: Double?
    public var inaccuracies = 0
    public var mistakes = 0
    public var blunders = 0
    public init() {}
}

/// One scored move for `PhaseReport`.
public struct ScoredMove: Sendable {
    public var side: Side
    public var phase: GamePhase
    public var loss: Double              // win-probability points lost
    public var severity: Int             // 0 none, 1 inaccuracy, 2 mistake, 3 blunder
    public init(side: Side, phase: GamePhase, loss: Double, severity: Int) {
        self.side = side; self.phase = phase; self.loss = loss; self.severity = severity
    }
}

public enum PhaseReport {
    /// Per-move accuracy from win-probability points lost (lichess's formula).
    public static func accuracy(loss: Double) -> Double {
        max(0, min(100, 103.1668 * exp(-0.04354 * loss) - 3.1669))
    }

    /// Per-side, per-phase accuracy. Phases with no moves are absent.
    public static func compute(_ moves: [ScoredMove]) -> [Side: [GamePhase: PhaseStat]] {
        var out: [Side: [GamePhase: PhaseStat]] = [:]
        var sums: [Side: [GamePhase: Double]] = [:]
        for m in moves {
            var s = out[m.side, default: [:]][m.phase, default: PhaseStat()]
            s.moves += 1
            switch m.severity {
            case 1: s.inaccuracies += 1
            case 2: s.mistakes += 1
            case 3: s.blunders += 1
            default: break
            }
            out[m.side, default: [:]][m.phase] = s
            sums[m.side, default: [:]][m.phase, default: 0] += accuracy(loss: m.loss)
        }
        for (side, phases) in out {
            for (ph, s) in phases { out[side]![ph]!.accuracy = (sums[side]?[ph] ?? 0) / Double(s.moves) }
        }
        return out
    }

    /// The phase with the highest and the lowest accuracy (needs at least 2 moves in a phase to count).
    public static func extremes(_ phases: [GamePhase: PhaseStat]) -> (best: GamePhase, worst: GamePhase)? {
        let scored = phases.filter { $0.value.moves >= 2 && $0.value.accuracy != nil }
        guard scored.count >= 2,
              let best = scored.max(by: { $0.value.accuracy! < $1.value.accuracy! })?.key,
              let worst = scored.min(by: { $0.value.accuracy! < $1.value.accuracy! })?.key, best != worst else { return nil }
        return (best, worst)
    }
}
