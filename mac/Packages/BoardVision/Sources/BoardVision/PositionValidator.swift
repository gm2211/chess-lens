import Foundation

/// Turns per-square class probabilities into a legal-looking position.
/// Squares are indexed `rank * 8 + file` from White's point of view (0 = a1, 63 = h8); classes follow
/// `PieceNet.classLabels` (0 empty, 1...6 white P N B R Q K, 7...12 black P N B R Q K).
enum PositionValidator {
    static let whitePawn = 1, whiteKing = 6, blackPawn = 7, blackKing = 12

    struct Result {
        var classes: [Int]
        /// Probability of the chosen class at each square.
        var confidence: [Float]
    }

    private static let fenChars: [Character?] = [nil, "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]

    static func resolve(_ probs: [[Float]]) -> Result {
        precondition(probs.count == 64)
        var classes = probs.map { p in p.enumerated().max { $0.element < $1.element }!.offset }

        func best(_ sq: Int, excluding: Set<Int>) -> Int {
            let rank = sq / 8
            var bestClass = 0
            var bestP: Float = -1
            for c in 0..<13 {
                if excluding.contains(c) { continue }
                if (c == whitePawn || c == blackPawn) && (rank == 0 || rank == 7) { continue }
                if probs[sq][c] > bestP { bestP = probs[sq][c]; bestClass = c }
            }
            return bestClass
        }

        for _ in 0..<6 {
            var changed = false
            // No pawns on the first or last rank.
            for sq in 0..<64 where (classes[sq] == whitePawn || classes[sq] == blackPawn) && (sq / 8 == 0 || sq / 8 == 7) {
                classes[sq] = best(sq, excluding: [])
                changed = true
            }
            // Exactly one king per side.
            for king in [whiteKing, blackKing] {
                let other = king == whiteKing ? blackKing : whiteKing
                let kings = (0..<64).filter { classes[$0] == king }
                if kings.count > 1 {
                    let keep = kings.max { probs[$0][king] < probs[$1][king] }!
                    for sq in kings where sq != keep { classes[sq] = best(sq, excluding: [king]) }
                    changed = true
                } else if kings.isEmpty {
                    if let sq = (0..<64).filter({ classes[$0] != other }).max(by: { probs[$0][king] < probs[$1][king] }) {
                        classes[sq] = king
                        changed = true
                    }
                }
            }
            // At most eight pawns per side.
            for pawn in [whitePawn, blackPawn] {
                let pawns = (0..<64).filter { classes[$0] == pawn }.sorted { probs[$0][pawn] > probs[$1][pawn] }
                if pawns.count > 8 {
                    for sq in pawns.dropFirst(8) { classes[sq] = best(sq, excluding: [pawn]) }
                    changed = true
                }
            }
            if !changed { break }
        }
        return Result(classes: classes, confidence: (0..<64).map { probs[$0][classes[$0]] })
    }

    /// FEN piece-placement field (rank 8 first).
    static func fen(_ classes: [Int]) -> String {
        var ranks: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var s = ""
            var empty = 0
            for file in 0..<8 {
                if let ch = fenChars[classes[rank * 8 + file]] {
                    if empty > 0 { s += String(empty); empty = 0 }
                    s.append(ch)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { s += String(empty) }
            ranks.append(s)
        }
        return ranks.joined(separator: "/")
    }

    static func squareName(_ sq: Int) -> String {
        "\(Character(UnicodeScalar(UInt8(97 + sq % 8))))\(sq / 8 + 1)"
    }
}
