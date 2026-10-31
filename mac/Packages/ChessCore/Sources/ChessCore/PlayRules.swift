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

/// Opponent strength for playing against Stockfish, implemented with `UCI_LimitStrength` / `UCI_Elo`.
public enum PlayStrength: String, Sendable, CaseIterable, Identifiable {
    case beginner, club, expert, master, full

    public var id: String { rawValue }

    /// Stockfish 18 accepts `UCI_Elo` in this range.
    public static let eloRange = 1320...3190

    public static func clampedElo(_ elo: Int) -> Int { min(eloRange.upperBound, max(eloRange.lowerBound, elo)) }

    /// Target Elo; nil means full strength (limiting switched off).
    public var elo: Int? {
        switch self {
        case .beginner: Self.clampedElo(1350)
        case .club: Self.clampedElo(1800)
        case .expert: Self.clampedElo(2200)
        case .master: Self.clampedElo(2600)
        case .full: nil
        }
    }

    public var label: String {
        switch self {
        case .beginner: "Beginner"
        case .club: "Club"
        case .expert: "Expert"
        case .master: "Master"
        case .full: "Full strength"
        }
    }

    /// "Club (1800)" or "Full strength".
    public var detail: String { elo.map { "\(label) (\($0))" } ?? label }

    /// UCI `setoption` pairs that select this strength.
    public var uciOptions: [(name: String, value: String)] {
        if let elo { return [("UCI_LimitStrength", "true"), ("UCI_Elo", String(elo))] }
        return [("UCI_LimitStrength", "false")]
    }
}
