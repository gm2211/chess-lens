import Foundation

/// How a game ended on the board.
public enum GameEnd: Sendable, Equatable {
    case checkmate(winner: Side)
    case stalemate
    case insufficientMaterial
    case fiftyMoveRule
    case threefoldRepetition

    public var winner: Side? {
        if case .checkmate(let w) = self { return w }
        return nil
    }

    public var isDraw: Bool { winner == nil }

    /// PGN result tag.
    public var pgnResult: String {
        switch winner {
        case .white?: "1-0"
        case .black?: "0-1"
        case nil: "1/2-1/2"
        }
    }

    public var title: String {
        switch self {
        case .checkmate: "Checkmate"
        case .stalemate: "Stalemate"
        case .insufficientMaterial: "Draw by insufficient material"
        case .fiftyMoveRule: "Draw by the fifty-move rule"
        case .threefoldRepetition: "Draw by threefold repetition"
        }
    }
}

extension Position {
    /// Placement, side to move, castling and en passant: what makes two positions "the same" for repetition.
    var repetitionKey: String {
        let parts = fen.split(separator: " ")
        return parts.prefix(4).joined(separator: " ")
    }

    /// Checkmate, stalemate, insufficient material or the fifty-move rule. Repetition needs the game history.
    public var gameEnd: GameEnd? {
        if isCheckmate { return .checkmate(winner: turn.opposite) }
        if isStalemate { return .stalemate }
        if isInsufficientMaterial { return .insufficientMaterial }
        if halfmove >= 100 { return .fiftyMoveRule }
        return nil
    }
}

extension Game {
    /// Why the game is over at `node`, if it is; includes threefold repetition along the path from the root.
    public func gameEnd(at node: Int) -> GameEnd? {
        guard nodes.indices.contains(node) else { return nil }
        let pos = nodes[node].position
        if let end = pos.gameEnd { return end }
        let key = pos.repetitionKey
        let seen = path(to: node).filter { nodes[$0].position.repetitionKey == key }.count
        return seen >= 3 ? .threefoldRepetition : nil
    }

    /// Where "take back" lands from `node` when `userSide` is playing: the user's previous turn,
    /// never before `anchor` (the node the session started or resumed from). Nil when there is nothing to take back.
    public func takeBackTarget(from node: Int, userSide: Side, anchor: Int) -> Int? {
        let line = path(to: node)
        guard let floor = line.firstIndex(of: anchor), let here = line.firstIndex(of: node) else { return nil }
        for i in stride(from: here - 1, through: floor, by: -1) where nodes[line[i]].position.turn == userSide {
            return line[i]
        }
        return nil
    }
}

/// Opponent strength for playing against Stockfish: a target Elo (`UCI_LimitStrength` / `UCI_Elo`) or full strength.
///
/// Stockfish turns the Elo into a fractional skill level, runs a 4-line MultiPV search and, once iterative deepening
/// finishes depth 1 + level, picks one of those lines with deliberate randomness; deeper results are thrown away.
/// So below full strength the think time barely matters as long as the search reaches that depth.
public struct PlayStrength: Sendable, Equatable, Hashable {
    /// Stockfish 18 accepts `UCI_Elo` in this range (`Skill::LowestElo` / `HighestElo` in search.h).
    public static let eloRange = 1320...3190

    /// Target Elo; nil means full strength (limiting switched off).
    public let elo: Int?

    public init(elo: Int?) { self.elo = elo.map(Self.clampedElo) }

    public static let full = PlayStrength(elo: nil)

    public static func clampedElo(_ elo: Int) -> Int { min(eloRange.upperBound, max(eloRange.lowerBound, elo)) }

    /// Labelled stops on the slider.
    public static let presets: [(label: String, strength: PlayStrength)] = [
        ("Beginner", PlayStrength(elo: 1350)), ("Club", PlayStrength(elo: 1800)), ("Expert", PlayStrength(elo: 2200)),
        ("Master", PlayStrength(elo: 2600)), ("Full", .full),
    ]

    /// The old saved preset names ("play.strength" before the Elo slider).
    public init?(legacyPreset raw: String) {
        switch raw {
        case "beginner": self.init(elo: 1350)
        case "club": self.init(elo: 1800)
        case "expert": self.init(elo: 2200)
        case "master": self.init(elo: 2600)
        case "full": self = .full
        default: return nil
        }
    }

    /// Stockfish 18's `Skill(skill_level, uci_elo)`: a cubic fit of Elo onto a fractional level, clamped to 0...19.
    public static func skillLevel(forElo elo: Int) -> Double {
        let e = Double(clampedElo(elo) - eloRange.lowerBound) / Double(eloRange.upperBound - eloRange.lowerBound)
        return min(19, max(0, ((37.2473 * e - 40.8525) * e + 22.2943) * e - 0.311438))
    }

    /// Fractional skill level (0...19); nil at full strength (level 20, no handicap).
    public var skillLevel: Double? { elo.map(Self.skillLevel(forElo:)) }

    /// Depth (half-moves) at which Stockfish picks its move: `Skill::time_to_pick` is `depth == 1 + int(level)`.
    public var pickDepth: Int? { skillLevel.map { 1 + Int($0) } }

    /// Search time when strength is limited: enough to finish `pickDepth` with 4 lines on 4 threads in a busy
    /// middlegame (measured with Stockfish 18), so the pick always happens; later iterations are discarded anyway.
    public var limitedMoveTime: Int? {
        guard let d = pickDepth else { return nil }
        switch d {
        case ...9: return 250
        case ...11: return 400
        case ...13: return 700
        case ...15: return 1200
        case ...17: return 2000
        default: return 3500
        }
    }

    /// The engine's search time: the derived one below full strength, the player's choice at full strength.
    public func moveTime(fullStrengthMillis: Int) -> Int { limitedMoveTime ?? fullStrengthMillis }

    /// "Stockfish 1850" or "Stockfish (full strength)".
    public var title: String { elo.map { "Stockfish \($0)" } ?? "Stockfish (full strength)" }

    /// The preset this matches exactly, if any ("Club").
    public var presetLabel: String? { Self.presets.first { $0.strength == self }?.label }

    /// One plain-English line about how it plays.
    public var note: String {
        guard let level = skillLevel else {
            return "No handicap: it plays its best move, and thinking longer makes it stronger."
        }
        switch level {
        case ..<3: return "Plays almost at random among its top moves and often drops material."
        case ..<7: return "Makes deliberate human-like mistakes and misses tactics a few moves deep."
        case ..<12: return "Plays solid chess with occasional deliberate inaccuracies."
        default: return "Strong and rarely wrong; its deliberate mistakes are small."
        }
    }

    /// UCI `setoption` pairs that select this strength.
    public var uciOptions: [(name: String, value: String)] {
        if let elo { return [("UCI_LimitStrength", "true"), ("UCI_Elo", String(elo))] }
        return [("UCI_LimitStrength", "false")]
    }
}
