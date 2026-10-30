import Foundation
import ChessCore

/// A piece with a stable identity, so SwiftUI can slide it from square to square.
struct PieceInstance: Identifiable, Equatable {
    let id: Int
    var piece: Piece
    var square: Square
}

enum PieceLayout {
    static func initial(_ pos: Position) -> [PieceInstance] {
        pos.board.enumerated().compactMap { i, p in p.map { PieceInstance(id: i, piece: $0, square: i) } }
    }

    /// Layout after `move` (made in `before`), keeping the identity of every surviving piece.
    static func applying(_ move: Move, before: Position, to layout: [PieceInstance]) -> [PieceInstance] {
        var out = layout
        guard let moverIdx = out.firstIndex(where: { $0.square == move.from }) else { return layout }
        let mover = out[moverIdx]
        // Captures (including en passant)
        var captured = out.firstIndex(where: { $0.square == move.to })
        if captured == nil, mover.piece.type == .pawn, Sq.file(move.from) != Sq.file(move.to) {
            let epSq = Sq.make(file: Sq.file(move.to), rank: Sq.rank(move.from))
            captured = out.firstIndex(where: { $0.square == epSq })
        }
        // Castling: move the rook too
        if mover.piece.type == .king, abs(Sq.file(move.to) - Sq.file(move.from)) == 2 {
            let (rookFrom, rookTo) = move.to > move.from ? (move.to + 1, move.to - 1) : (move.to - 2, move.to + 1)
            if let r = out.firstIndex(where: { $0.square == rookFrom }) { out[r].square = rookTo }
        }
        out[moverIdx].square = move.to
        if let promo = move.promotion { out[moverIdx].piece = Piece(mover.piece.color, promo) }
        if let c = captured, c != moverIdx { out.remove(at: c) }
        return out
    }
}
