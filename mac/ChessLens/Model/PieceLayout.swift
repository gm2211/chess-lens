import Foundation
import ChessCore

/// A piece with a stable identity, so SwiftUI can slide it from square to square.
typealias PieceInstance = TrackedPiece

enum PieceLayout {
    static func initial(_ pos: Position) -> [PieceInstance] { PieceMotion.initial(pos.board) }

    /// Layout after `move` (made in `before`), keeping the identity of every surviving piece.
    static func applying(_ move: Move, before: Position, to layout: [PieceInstance]) -> [PieceInstance] {
        PieceMotion.applying(move, to: layout)
    }
}
