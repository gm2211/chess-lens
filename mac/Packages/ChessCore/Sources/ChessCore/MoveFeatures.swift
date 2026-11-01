import Foundation

/// What a move does on the board, in the terms a narrator uses: check, mate, what it takes, what it leaves hanging.
public struct MoveFeatures: Equatable, Sendable {
    public var check = false
    public var mate = false
    public var captured: Piece?
    public var promotion: PieceType?
    /// Enemy pieces hanging after the move that were not before (most valuable first, no king).
    public var hanging: [Square] = []
    /// Where the mover would mate next move if left alone (nil when there is no such threat or the move checks).
    public var mateThreat: Square?
}

extension Position {
    /// Pieces of `side` attacking `sq`, counting batteries (a queen behind a bishop on the same diagonal).
    public func attackerCount(_ sq: Square, by side: Side) -> Int {
        let f = Sq.file(sq), r = Sq.rank(sq)
        func at(_ nf: Int, _ nr: Int) -> Piece? {
            (0..<8).contains(nf) && (0..<8).contains(nr) ? board[Sq.make(file: nf, rank: nr)] : nil
        }
        var n = 0
        let pr = side == .white ? r - 1 : r + 1
        for df in [-1, 1] where at(f + df, pr) == Piece(side, .pawn) { n += 1 }
        for (df, dr) in Position.knightDeltas where at(f + df, r + dr) == Piece(side, .knight) { n += 1 }
        for (df, dr) in Position.kingDeltas where at(f + df, r + dr) == Piece(side, .king) { n += 1 }
        let rays: [([(Int, Int)], [PieceType])] = [(Position.bishopDirs, [.bishop, .queen]), (Position.rookDirs, [.rook, .queen])]
        for (dirs, kinds) in rays {
            for (df, dr) in dirs {
                var nf = f + df, nr = r + dr
                while (0..<8).contains(nf), (0..<8).contains(nr) {
                    if let p = board[Sq.make(file: nf, rank: nr)] {
                        guard p.color == side, kinds.contains(p.type) else { break }
                        n += 1
                    }
                    nf += df; nr += dr
                }
            }
        }
        return n
    }

    /// The cheapest piece of `side` attacking `sq` directly, by value.
    func cheapestAttacker(_ sq: Square, by side: Side) -> Int? {
        board.indices.compactMap { s -> Int? in
            guard let p = board[s], p.color == side, attackedSquares(from: s).contains(sq) else { return nil }
            return p.type.value
        }.min()
    }

    /// The piece on `sq` (not a king) can be taken for profit: attacked and undefended, attacked by something
    /// cheaper, or attacked more often than defended.
    public func isHanging(_ sq: Square) -> Bool {
        guard let p = board[sq], p.type != .king else { return false }
        let attackers = attackerCount(sq, by: p.color.opposite)
        guard attackers > 0 else { return false }
        let defenders = attackerCount(sq, by: p.color)
        if defenders == 0 || attackers > defenders { return true }
        return (cheapestAttacker(sq, by: p.color.opposite) ?? 100) < p.type.value
    }

    /// What `m` (legal here) does. Hanging pieces are the opponent's that are hanging afterwards but were not before.
    public func features(_ m: Move) -> MoveFeatures {
        guard let mover = board[m.from]?.color else { return MoveFeatures() }
        let after = applyingUnchecked(m)
        var f = MoveFeatures()
        f.check = after.isCheck
        f.mate = f.check && after.legalMoves().isEmpty
        f.captured = board[m.to] ?? (board[m.from]?.type == .pawn && Sq.file(m.from) != Sq.file(m.to)
                                     ? Piece(mover.opposite, .pawn) : nil)
        f.promotion = m.promotion
        f.hanging = after.board.indices.filter { s in
            guard let p = after.board[s], p.color == mover.opposite, after.isHanging(s) else { return false }
            return board[s] != p || !isHanging(s)
        }.sorted { (after.board[$0]?.type.value ?? 0) > (after.board[$1]?.type.value ?? 0) }
        if !f.check { f.mateThreat = after.mateInOne(for: mover) }
        return f
    }

    /// The square `side` would mate on if it could move again now (a null move); nil if none.
    func mateInOne(for side: Side) -> Square? {
        var p = self
        p.turn = side; p.epSquare = nil
        guard !p.isCheck, let k = p.kingSquare(side.opposite), !p.isAttacked(k, by: side) else { return nil }
        return p.legalMoves().first { p.applyingUnchecked($0).isCheckmate }?.to
    }

    /// The move as a person says it: "queen b3", "knight takes f7", "e takes d5", "castles long", with ", check".
    public func spoken(_ m: Move) -> String {
        guard let p = board[m.from] else { return m.uci }
        var s: String
        if p.type == .king, abs(Sq.file(m.to) - Sq.file(m.from)) == 2 {
            s = m.to > m.from ? "castles" : "castles long"
        } else if p.type == .pawn {
            s = Sq.file(m.from) != Sq.file(m.to) ? "\(Sq.name(m.from).prefix(1)) takes \(Sq.name(m.to))" : Sq.name(m.to)
        } else {
            s = p.type.name + (board[m.to] != nil ? " takes " : " ") + Sq.name(m.to)
        }
        if let promo = m.promotion { s += ", promoting to a \(promo.name)" }
        let next = applyingUnchecked(m)
        if next.isCheck { s += next.legalMoves().isEmpty ? ", checkmate" : ", check" }
        return s
    }

    /// "b7" for a pawn, "the knight on c6" for a piece.
    public func spokenTarget(_ sq: Square) -> String {
        guard let p = board[sq], p.type != .pawn else { return Sq.name(sq) }
        return "the \(p.type.name) on \(Sq.name(sq))"
    }
}
