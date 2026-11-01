import Foundation

/// A piece with a stable identity, so a board view can slide it from square to square instead of redrawing it.
public struct TrackedPiece: Identifiable, Equatable, Sendable {
    public let id: Int
    public var piece: Piece
    public var square: Square
    public init(id: Int, piece: Piece, square: Square) { self.id = id; self.piece = piece; self.square = square }
}

/// Pure piece-identity matching between boards: which piece went where when moves are made.
public enum PieceMotion {
    /// One piece's journey across a run of moves.
    public struct Slide: Equatable, Sendable {
        public var id: Int
        public var from: Square
        /// Where it ends; nil when it was captured on the way.
        public var to: Square?
        public var piece: Piece
        /// The piece it ends up as (differs from `piece` after a promotion).
        public var finalPiece: Piece
        public var isPromotion: Bool { finalPiece != piece }
        public var moved: Bool { to != from }
    }

    /// Identity = the starting square of the piece on `board`.
    public static func initial(_ board: [Piece?]) -> [TrackedPiece] {
        board.enumerated().compactMap { i, p in p.map { TrackedPiece(id: i, piece: $0, square: i) } }
    }

    /// Layout after `move`, keeping the identity of every surviving piece (captures incl. en passant, castling
    /// rook, promotion). A move that doesn't fit the layout leaves it unchanged.
    public static func applying(_ move: Move, to layout: [TrackedPiece]) -> [TrackedPiece] {
        var out = layout
        guard let moverIdx = out.firstIndex(where: { $0.square == move.from }) else { return layout }
        let mover = out[moverIdx]
        var captured = out.firstIndex(where: { $0.square == move.to })
        if captured == nil, mover.piece.type == .pawn, Sq.file(move.from) != Sq.file(move.to) {
            let epSq = Sq.make(file: Sq.file(move.to), rank: Sq.rank(move.from))
            captured = out.firstIndex(where: { $0.square == epSq })
        }
        if mover.piece.type == .king, abs(Sq.file(move.to) - Sq.file(move.from)) == 2 {
            let (rookFrom, rookTo) = move.to > move.from ? (move.to + 1, move.to - 1) : (move.to - 2, move.to + 1)
            if let r = out.firstIndex(where: { $0.square == rookFrom }) { out[r].square = rookTo }
        }
        out[moverIdx].square = move.to
        if let promo = move.promotion { out[moverIdx].piece = Piece(mover.piece.color, promo) }
        if let c = captured, c != moverIdx { out.remove(at: c) }
        return out
    }

    /// Per-piece from -> to mapping from `board` through `moves` (legal, in order). Only pieces that moved,
    /// were captured or promoted are listed.
    public static func slides(board: [Piece?], moves: [Move]) -> [Slide] {
        let start = initial(board)
        var layout = start
        for m in moves { layout = applying(m, to: layout) }
        return start.compactMap { s in
            let end = layout.first { $0.id == s.id }
            let slide = Slide(id: s.id, from: s.square, to: end?.square, piece: s.piece, finalPiece: end?.piece ?? s.piece)
            return slide.to == s.square && !slide.isPromotion ? nil : slide
        }
    }

    /// The node ids to visit, in order, to walk from `from` to `to` along tree ancestry (either direction), so a
    /// player can replay the moves in between. Up to `maxAnimated` hops are walked; if there are more than
    /// `threshold`, the first element is where the rest is skipped to in one jump, followed by the last `maxAnimated`.
    /// Nodes not on a common ancestor line give just `[to]`
    /// (a jump). `parent` maps a node id to its parent.
    public static func hops(from: Int, to: Int, parent: (Int) -> Int?, threshold: Int = 6, maxAnimated: Int = 4) -> [Int] {
        if from == to { return [] }
        func chain(_ leaf: Int, upTo anc: Int) -> [Int]? {   // nodes after `anc` down to `leaf`
            var out = [leaf], cur = leaf
            while let p = parent(cur) {
                if p == anc { return out.reversed() }
                out.append(p); cur = p
            }
            return nil
        }
        var path: [Int]
        if let down = chain(to, upTo: from) {
            path = down
        } else if let up = chain(from, upTo: to) {
            path = Array(up.dropLast().reversed()) + [to]
        } else {
            return [to]
        }
        // First element = the instant jump; then the last `maxAnimated` hops.
        if path.count > threshold { path = Array(path.suffix(maxAnimated + 1)) }
        return path
    }
}
