import Foundation

/// Prompt for the AI coach's explanation of one reviewed move. Pure, so it can be tested.
public enum CoachPrompt {
    public static let system = """
    You are a concise chess coach reviewing one move from a game the user played. \
    In 2 to 4 sentences of plain English, explain concretely what the move allowed or missed, \
    and what the idea of the better line was. \
    Ground every claim in the lines and facts provided. Never mention or invent moves, captures, \
    squares or tactics that are not in those lines or the game so far; if the lines do not show something, do not claim it. \
    Refer to moves in SAN. No preamble, no headings, no bullet points, no markdown.
    """

    /// - Parameters:
    ///   - before: the position before the move.
    ///   - move: the move played.
    ///   - classification: e.g. "blunder", "mistake", "inaccuracy"; nil if none.
    ///   - evalBefore/evalAfter: engine scores from White's point of view; shown from the mover's.
    ///   - tags: deterministic tags from `lineTags`.
    ///   - refutation: UCI line from the position after the move. best: UCI line from `before`.
    ///   - history: SAN of the moves played before `move`, from the start of the game.
    public static func user(before: Position, move: Move, classification: String?,
                            evalBefore: Eval?, evalAfter: Eval?, tags: [LineTag],
                            refutation: [String], best: [String], history: [String],
                            maxPlies: Int = 8) -> String {
        let mover = before.turn
        let after = before.applyingUnchecked(move)
        var out: [String] = []
        out.append("Position before the move (FEN): \(before.fen)")
        out.append("Side to move: \(mover == .white ? "White" : "Black")")
        let num = "\(before.fullmove)\(mover == .white ? "." : "\u{2026}")"
        out.append("Move played: \(num) \(before.san(move))" + (classification.map { " (\($0))" } ?? ""))
        if let b = evalBefore, let a = evalAfter {
            out.append("Evaluation from the mover's point of view: \(pov(b, mover)) before, \(pov(a, mover)) after")
        }
        if !tags.isEmpty { out.append("Tags: " + tags.map(\.text).joined(separator: "; ")) }
        let ref = after.numberedLine(fromUCI: refutation, maxPlies: maxPlies)
        if !ref.isEmpty { out.append("Engine line after the move played (refutation or threat): \(ref)") }
        let bst = before.numberedLine(fromUCI: best, maxPlies: maxPlies)
        if !bst.isEmpty { out.append("Engine's better line instead: \(bst)") }
        out.append("Game so far: " + (history.isEmpty ? "(start of game)" : numbered(history, endingBefore: before)))
        return out.joined(separator: "\n")
    }

    /// Score from `side`'s point of view: "+0.35", "-1.20", "mate in 3 for the mover".
    static func pov(_ e: Eval, _ side: Side) -> String {
        switch e {
        case .cp(let c): return Eval.cp(side == .white ? c : -c).display
        case .mate(let m):
            let mine = side == .white ? m > 0 : m < 0
            return mine ? "mate in \(abs(m)) for the mover" : "mate in \(abs(m)) against the mover"
        case .checkmate(let w): return w == side ? "mate delivered" : "checkmated"
        }
    }

    private static func numbered(_ sans: [String], endingBefore pos: Position) -> String {
        var ply = (pos.fullmove - 1) * 2 + (pos.turn == .white ? 0 : 1) - sans.count
        var parts: [String] = []
        for (i, s) in sans.enumerated() {
            if ply % 2 == 0 { parts.append("\(ply / 2 + 1).") } else if i == 0 { parts.append("\(ply / 2 + 1)\u{2026}") }
            parts.append(s)
            ply += 1
        }
        return parts.joined(separator: " ")
    }
}
