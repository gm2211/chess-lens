import Foundation

public struct Position: Sendable, Hashable {
    public var board: [Piece?]            // 64 entries, index = Square
    public var turn: Side
    public var castling: CastlingRights
    public var epSquare: Square?
    public var halfmove: Int
    public var fullmove: Int

    public static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    public static let start: Position = try! Position(fen: startFEN)

    public init(board: [Piece?], turn: Side, castling: CastlingRights, epSquare: Square?, halfmove: Int, fullmove: Int) {
        self.board = board; self.turn = turn; self.castling = castling
        self.epSquare = epSquare; self.halfmove = halfmove; self.fullmove = fullmove
    }

    // MARK: FEN

    /// Parses a FEN. Missing trailing fields are tolerated ("placement" alone, or "placement turn").
    public init(fen: String) throws {
        let parts = fen.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard parts.count >= 1 else { throw ChessError.invalidFEN("empty") }
        let board = try Position.parseBoard(parts[0])
        var turn = Side.white
        if parts.count > 1 {
            switch parts[1] {
            case "w": turn = .white
            case "b": turn = .black
            default: throw ChessError.invalidFEN("side to move must be w or b")
            }
        }
        var castling: CastlingRights = []
        if parts.count > 2 {
            for ch in parts[2] where ch != "-" {
                switch ch {
                case "K": castling.insert(.whiteKingside)
                case "Q": castling.insert(.whiteQueenside)
                case "k": castling.insert(.blackKingside)
                case "q": castling.insert(.blackQueenside)
                default: throw ChessError.invalidFEN("bad castling field")
                }
            }
        } else if parts.count == 1 || parts.count == 2 {
            castling = []
        }
        var ep: Square?
        if parts.count > 3, parts[3] != "-" {
            guard let s = Sq.parse(parts[3]) else { throw ChessError.invalidFEN("bad en passant square") }
            ep = s
        }
        let half = parts.count > 4 ? (Int(parts[4]) ?? 0) : 0
        let full = parts.count > 5 ? max(1, Int(parts[5]) ?? 1) : 1
        self.init(board: board, turn: turn, castling: castling, epSquare: ep, halfmove: half, fullmove: full)
        // Drop castling rights that are impossible given piece placement.
        sanitizeCastling()
        if let ep = epSquare, !isEnPassantPlausible(ep) { epSquare = nil }
        try validate()
    }

    /// Parses a FEN piece-placement field without validating the position (kings, pawns on back ranks).
    public static func parseBoard(_ placement: String) throws -> [Piece?] {
        var board = [Piece?](repeating: nil, count: 64)
        let rows = placement.split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { throw ChessError.invalidFEN("expected 8 ranks, found \(rows.count)") }
        for (i, row) in rows.enumerated() {
            let rank = 7 - i
            var file = 0
            for ch in row {
                if let n = ch.wholeNumberValue, (1...8).contains(n) {
                    file += n
                } else if let p = Piece(fen: ch) {
                    guard file < 8 else { throw ChessError.invalidFEN("rank \(rank + 1) is too long") }
                    board[Sq.make(file: file, rank: rank)] = p
                    file += 1
                } else {
                    throw ChessError.invalidFEN("unexpected character '\(ch)'")
                }
            }
            guard file == 8 else { throw ChessError.invalidFEN("rank \(rank + 1) has \(file) files") }
        }
        return board
    }

    public var placementFEN: String {
        var out = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for file in 0..<8 {
                if let p = board[Sq.make(file: file, rank: rank)] {
                    if empty > 0 { out += String(empty); empty = 0 }
                    out.append(p.fenChar)
                } else { empty += 1 }
            }
            if empty > 0 { out += String(empty) }
            if rank > 0 { out += "/" }
        }
        return out
    }

    public var fen: String {
        "\(placementFEN) \(turn == .white ? "w" : "b") \(castling.fen) \(epSquare.map(Sq.name) ?? "-") \(halfmove) \(fullmove)"
    }

    mutating func sanitizeCastling() {
        func has(_ s: Square, _ p: Piece) -> Bool { board[s] == p }
        if !has(4, Piece(.white, .king)) { castling.subtract([.whiteKingside, .whiteQueenside]) }
        if !has(7, Piece(.white, .rook)) { castling.remove(.whiteKingside) }
        if !has(0, Piece(.white, .rook)) { castling.remove(.whiteQueenside) }
        if !has(60, Piece(.black, .king)) { castling.subtract([.blackKingside, .blackQueenside]) }
        if !has(63, Piece(.black, .rook)) { castling.remove(.blackKingside) }
        if !has(56, Piece(.black, .rook)) { castling.remove(.blackQueenside) }
    }

    func isEnPassantPlausible(_ ep: Square) -> Bool {
        let rank = Sq.rank(ep)
        if turn == .white { return rank == 5 && board[ep - 8] == Piece(.black, .pawn) }
        return rank == 2 && board[ep + 8] == Piece(.white, .pawn)
    }

    /// Throws when the position cannot arise in a game (kings, pawns on back ranks, side not to move in check).
    public func validate() throws {
        var wk = 0, bk = 0
        for (i, p) in board.enumerated() {
            guard let p else { continue }
            if p.type == .king { if p.color == .white { wk += 1 } else { bk += 1 } }
            if p.type == .pawn, Sq.rank(i) == 0 || Sq.rank(i) == 7 { throw ChessError.invalidFEN("pawn on the first or last rank") }
        }
        guard wk == 1, bk == 1 else { throw ChessError.invalidFEN("each side needs exactly one king") }
        if let k = kingSquare(turn.opposite), isAttacked(k, by: turn) {
            throw ChessError.invalidFEN("the side not to move is in check")
        }
    }

    // MARK: Queries

    public func piece(at s: Square) -> Piece? { board[s] }

    public func kingSquare(_ c: Side) -> Square? {
        for i in 0..<64 where board[i] == Piece(c, .king) { return i }
        return nil
    }

    public var isCheck: Bool {
        guard let k = kingSquare(turn) else { return false }
        return isAttacked(k, by: turn.opposite)
    }

    static let knightDeltas: [(Int, Int)] = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    static let kingDeltas: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    static let bishopDirs: [(Int, Int)] = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
    static let rookDirs: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    public func isAttacked(_ sq: Square, by c: Side) -> Bool {
        let f = Sq.file(sq), r = Sq.rank(sq)
        // Pawns: a white pawn attacks upward, so it sits one rank below the target.
        let pr = c == .white ? r - 1 : r + 1
        if (0..<8).contains(pr) {
            for df in [-1, 1] {
                let pf = f + df
                if (0..<8).contains(pf), board[Sq.make(file: pf, rank: pr)] == Piece(c, .pawn) { return true }
            }
        }
        for (df, dr) in Position.knightDeltas {
            let nf = f + df, nr = r + dr
            if (0..<8).contains(nf), (0..<8).contains(nr), board[Sq.make(file: nf, rank: nr)] == Piece(c, .knight) { return true }
        }
        for (df, dr) in Position.kingDeltas {
            let nf = f + df, nr = r + dr
            if (0..<8).contains(nf), (0..<8).contains(nr), board[Sq.make(file: nf, rank: nr)] == Piece(c, .king) { return true }
        }
        for (df, dr) in Position.bishopDirs {
            var nf = f + df, nr = r + dr
            while (0..<8).contains(nf), (0..<8).contains(nr) {
                if let p = board[Sq.make(file: nf, rank: nr)] {
                    if p.color == c, p.type == .bishop || p.type == .queen { return true }
                    break
                }
                nf += df; nr += dr
            }
        }
        for (df, dr) in Position.rookDirs {
            var nf = f + df, nr = r + dr
            while (0..<8).contains(nf), (0..<8).contains(nr) {
                if let p = board[Sq.make(file: nf, rank: nr)] {
                    if p.color == c, p.type == .rook || p.type == .queen { return true }
                    break
                }
                nf += df; nr += dr
            }
        }
        return false
    }

    // MARK: Move generation

    /// Pseudo-legal moves for the side to move (may leave own king in check).
    func pseudoLegalMoves() -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(48)
        let us = turn
        for from in 0..<64 {
            guard let p = board[from], p.color == us else { continue }
            let f = Sq.file(from), r = Sq.rank(from)
            switch p.type {
            case .pawn:
                let dir = us == .white ? 1 : -1
                let startRank = us == .white ? 1 : 6
                let lastRank = us == .white ? 7 : 0
                let nr = r + dir
                guard (0..<8).contains(nr) else { continue }
                func add(_ to: Square) {
                    if Sq.rank(to) == lastRank {
                        for t in [PieceType.queen, .rook, .bishop, .knight] { moves.append(Move(from: from, to: to, promotion: t)) }
                    } else { moves.append(Move(from: from, to: to)) }
                }
                let one = Sq.make(file: f, rank: nr)
                if board[one] == nil {
                    add(one)
                    if r == startRank {
                        let two = Sq.make(file: f, rank: nr + dir)
                        if board[two] == nil { moves.append(Move(from: from, to: two)) }
                    }
                }
                for df in [-1, 1] {
                    let nf = f + df
                    guard (0..<8).contains(nf) else { continue }
                    let to = Sq.make(file: nf, rank: nr)
                    if let t = board[to], t.color != us { add(to) }
                    else if to == epSquare, board[to] == nil { moves.append(Move(from: from, to: to)) }
                }
            case .knight:
                for (df, dr) in Position.knightDeltas { step(from, f + df, r + dr, us, &moves) }
            case .king:
                for (df, dr) in Position.kingDeltas { step(from, f + df, r + dr, us, &moves) }
                genCastling(from, us, &moves)
            case .bishop, .rook, .queen:
                if p.type != .rook { slide(from, Position.bishopDirs, us, &moves) }
                if p.type != .bishop { slide(from, Position.rookDirs, us, &moves) }
            }
        }
        return moves
    }

    @inline(__always)
    private func step(_ from: Square, _ nf: Int, _ nr: Int, _ us: Side, _ moves: inout [Move]) {
        guard (0..<8).contains(nf), (0..<8).contains(nr) else { return }
        let to = Sq.make(file: nf, rank: nr)
        if let t = board[to], t.color == us { return }
        moves.append(Move(from: from, to: to))
    }

    private func slide(_ from: Square, _ dirs: [(Int, Int)], _ us: Side, _ moves: inout [Move]) {
        let f = Sq.file(from), r = Sq.rank(from)
        for (df, dr) in dirs {
            var nf = f + df, nr = r + dr
            while (0..<8).contains(nf), (0..<8).contains(nr) {
                let to = Sq.make(file: nf, rank: nr)
                if let t = board[to] {
                    if t.color != us { moves.append(Move(from: from, to: to)) }
                    break
                }
                moves.append(Move(from: from, to: to))
                nf += df; nr += dr
            }
        }
    }

    private func genCastling(_ from: Square, _ us: Side, _ moves: inout [Move]) {
        let home = us == .white ? 4 : 60
        guard from == home else { return }
        let them = us.opposite
        let ks: CastlingRights = us == .white ? .whiteKingside : .blackKingside
        let qs: CastlingRights = us == .white ? .whiteQueenside : .blackQueenside
        guard castling.contains(ks) || castling.contains(qs), !isAttacked(home, by: them) else { return }
        if castling.contains(ks), board[home + 1] == nil, board[home + 2] == nil,
           board[home + 3] == Piece(us, .rook),
           !isAttacked(home + 1, by: them), !isAttacked(home + 2, by: them) {
            moves.append(Move(from: home, to: home + 2))
        }
        if castling.contains(qs), board[home - 1] == nil, board[home - 2] == nil, board[home - 3] == nil,
           board[home - 4] == Piece(us, .rook),
           !isAttacked(home - 1, by: them), !isAttacked(home - 2, by: them) {
            moves.append(Move(from: home, to: home - 2))
        }
    }

    public func legalMoves() -> [Move] {
        let us = turn
        return pseudoLegalMoves().filter { m in
            let next = applyingUnchecked(m)
            guard let k = next.kingSquare(us) else { return false }
            return !next.isAttacked(k, by: us.opposite)
        }
    }

    public func legalMoves(from sq: Square) -> [Move] { legalMoves().filter { $0.from == sq } }

    public func isLegal(_ m: Move) -> Bool { legalMoves().contains(m) }

    /// Applies a move without checking legality.
    func applyingUnchecked(_ m: Move) -> Position {
        var p = self
        guard let piece = p.board[m.from] else { return p }
        let isCapture = p.board[m.to] != nil
        var ep: Square?
        // En passant capture
        if piece.type == .pawn, m.to == epSquare, Sq.file(m.from) != Sq.file(m.to), p.board[m.to] == nil {
            p.board[Sq.make(file: Sq.file(m.to), rank: Sq.rank(m.from))] = nil
        }
        // Castling rook
        if piece.type == .king, abs(Sq.file(m.to) - Sq.file(m.from)) == 2 {
            if m.to > m.from { p.board[m.to - 1] = p.board[m.to + 1]; p.board[m.to + 1] = nil }
            else { p.board[m.to + 1] = p.board[m.to - 2]; p.board[m.to - 2] = nil }
        }
        p.board[m.to] = m.promotion.map { Piece(piece.color, $0) } ?? piece
        p.board[m.from] = nil
        if piece.type == .pawn, abs(Sq.rank(m.to) - Sq.rank(m.from)) == 2 {
            ep = (m.from + m.to) / 2
        }
        // Castling rights
        if piece.type == .king {
            p.castling.subtract(piece.color == .white ? [.whiteKingside, .whiteQueenside] : [.blackKingside, .blackQueenside])
        }
        for s in [m.from, m.to] {
            switch s {
            case 0: p.castling.remove(.whiteQueenside)
            case 7: p.castling.remove(.whiteKingside)
            case 56: p.castling.remove(.blackQueenside)
            case 63: p.castling.remove(.blackKingside)
            default: break
            }
        }
        p.epSquare = ep
        p.halfmove = (piece.type == .pawn || isCapture) ? 0 : p.halfmove + 1
        if turn == .black { p.fullmove += 1 }
        p.turn = turn.opposite
        return p
    }

    /// Applies a legal move; throws if it is not legal here.
    public func applying(_ m: Move) throws -> Position {
        guard isLegal(m) else { throw ChessError.illegalMove(m.uci) }
        return applyingUnchecked(m)
    }

    // MARK: Game state

    public var isCheckmate: Bool { isCheck && legalMoves().isEmpty }
    public var isStalemate: Bool { !isCheck && legalMoves().isEmpty }

    public var isInsufficientMaterial: Bool {
        var minors: [(PieceType, Square)] = []
        for (i, p) in board.enumerated() {
            guard let p else { continue }
            switch p.type {
            case .pawn, .rook, .queen: return false
            case .knight, .bishop: minors.append((p.type, i))
            case .king: break
            }
        }
        if minors.count <= 1 { return true }
        if minors.allSatisfy({ $0.0 == .bishop }) {
            return Set(minors.map { Sq.isLight($0.1) }).count == 1
        }
        return false
    }

    public func perft(_ depth: Int) -> Int {
        if depth == 0 { return 1 }
        let moves = legalMoves()
        if depth == 1 { return moves.count }
        var n = 0
        for m in moves { n += applyingUnchecked(m).perft(depth - 1) }
        return n
    }
}
