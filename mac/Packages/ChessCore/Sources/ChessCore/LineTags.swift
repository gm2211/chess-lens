import Foundation

/// A short, deterministic explanation of what a move allowed or missed.
public enum LineTag: Equatable, Sendable {
    case hangs(PieceType, Square)          // the played move leaves this piece en prise; the reply takes it
    case allowsFork                        // the reply forks the king/pieces
    case allowsMate(Int)                   // the opponent mates in n
    case missesCapture(PieceType, Square)  // the best move took a piece; the played move did not

    public var text: String {
        switch self {
        case .hangs(let t, let s): "hangs the \(t.name) on \(Sq.name(s))"
        case .allowsFork: "allows a fork"
        case .allowsMate(let n): "allows mate in \(n)"
        case .missesCapture(let t, let s): "misses taking the \(t.name) on \(Sq.name(s))"
        }
    }
}

extension PieceType {
    public var name: String {
        switch self {
        case .pawn: "pawn"
        case .knight: "knight"
        case .bishop: "bishop"
        case .rook: "rook"
        case .queen: "queen"
        case .king: "king"
        }
    }
    /// Conventional material value; the king is priceless.
    public var value: Int {
        switch self {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 100
        }
    }
}

extension Position {
    /// Squares attacked by the piece on `sq` (empty if none), ignoring pins.
    public func attackedSquares(from sq: Square) -> [Square] {
        guard let p = board[sq] else { return [] }
        let f = Sq.file(sq), r = Sq.rank(sq)
        var out: [Square] = []
        func inside(_ nf: Int, _ nr: Int) -> Bool { (0..<8).contains(nf) && (0..<8).contains(nr) }
        func steps(_ ds: [(Int, Int)]) {
            for (df, dr) in ds where inside(f + df, r + dr) { out.append(Sq.make(file: f + df, rank: r + dr)) }
        }
        func slide(_ ds: [(Int, Int)]) {
            for (df, dr) in ds {
                var nf = f + df, nr = r + dr
                while inside(nf, nr) {
                    out.append(Sq.make(file: nf, rank: nr))
                    if board[Sq.make(file: nf, rank: nr)] != nil { break }
                    nf += df; nr += dr
                }
            }
        }
        switch p.type {
        case .pawn: let d = p.color == .white ? 1 : -1; steps([(-1, d), (1, d)])
        case .knight: steps(Position.knightDeltas)
        case .king: steps(Position.kingDeltas)
        case .bishop: slide(Position.bishopDirs)
        case .rook: slide(Position.rookDirs)
        case .queen: slide(Position.bishopDirs); slide(Position.rookDirs)
        }
        return out
    }

    /// Explains `played` (made from `self`) using the engine's refutation line (from the resulting position),
    /// the best line from `self` and the evaluation after the move. Tags are only emitted when they are
    /// certain; an empty result means "no simple explanation".
    public func lineTags(played: Move, refutation: [String], best: [String], evalAfter: Eval?) -> [LineTag] {
        guard let mover = board[played.from]?.color, isLegal(played) else { return [] }
        var tags: [LineTag] = []
        let after = applyingUnchecked(played)

        if let e = evalAfter, case .mate(let n) = e, (mover == .white && n < 0) || (mover == .black && n > 0) {
            tags.append(.allowsMate(abs(n)))
        }

        let captured: Piece? = board[played.to].flatMap { $0.color != mover ? $0 : nil }
        if let first = refutation.first, let r = after.move(fromUCI: first) {
            if let victim = after.board[r.to], victim.color == mover, let attacker = after.board[r.from] {
                // En prise if the capture wins material or cannot be answered by a recapture.
                let defended = after.applyingUnchecked(r).isAttacked(r.to, by: mover)
                let wins = victim.type.value > attacker.type.value || !defended
                // The move must have caused it: the piece itself moved, or it was not attacked before.
                let caused = played.to == r.to || !isAttacked(r.to, by: mover.opposite)
                // Not a trade: the played move did not itself take something at least as valuable.
                let tradedUp = (captured?.type.value ?? 0) >= victim.type.value
                if wins, caused, !tradedUp, victim.type != .king { tags.append(.hangs(victim.type, r.to)) }
            } else if let forker = after.board[r.from], forker.type != .king {
                let next = after.applyingUnchecked(r)
                if !next.isAttacked(r.to, by: mover) {
                    let floor = max(forker.type.value, 3)
                    let targets = next.attackedSquares(from: r.to).filter { t in
                        guard let p = next.board[t], p.color == mover else { return false }
                        return p.type == .king || p.type.value >= floor
                    }
                    if targets.count >= 2 { tags.append(.allowsFork) }
                }
            }
        }

        if captured == nil, let first = best.first, let b = move(fromUCI: first),
           let victim = board[b.to], victim.color != mover, victim.type.value >= 3 {
            tags.append(.missesCapture(victim.type, b.to))
        }
        return tags
    }
}
