import Foundation

/// Prompt for the AI coach's lesson on one reviewed move. Pure, so it can be tested.
/// The engine has already picked the moment; the model's job is to teach the idea behind it.
public enum CoachPrompt {
    public static func system(tool: Bool) -> String {
        """
        You are a friendly chess coach helping an improving player learn from one moment of their game. \
        The engine already found the mistake; your job is to teach the idea behind it in plain English.
        Reply with only a JSON object:
        {"concept": "2-5 words naming the idea, e.g. lead in development, king stuck in the centre, overloaded defender, trading when ahead, loose piece",
        "idea": "1-2 sentences: why that concept mattered in this position",
        "whatWentWrong": "1-2 sentences: what the player probably had in mind, and what was really true",
        "betterIdea": "1-2 sentences: the better plan, with the engine's move as evidence",
        "rule": "1 sentence: a rule of thumb or thinking habit that finds the better move, and how to spot the pattern next time"}
        Write for a club player: plain words, little notation, no evaluation numbers. Cite at most 3 moves, and only \
        moves from the data or from engine results. Never say a piece is on a square unless the FEN shows it. \
        50 to 90 words in total.
        If the move was strong (great or brilliant), teach the idea that made it work instead: "whatWentWrong" says \
        what the opponent missed or allowed, "betterIdea" why the move works, "rule" the lesson to take from it.
        """ + (tool ? "\n" + EngineTool.instructions : "")
    }

    /// - Parameters:
    ///   - before: the position before the move.
    ///   - move: the move played.
    ///   - classification: e.g. "blunder", "mistake", "inaccuracy"; nil if none.
    ///   - evalBefore/evalAfter: engine scores from White's point of view; shown from the mover's.
    ///   - tags: deterministic tags from `lineTags`.
    ///   - refutation: UCI line from the position after the move. best: UCI line from `before`.
    ///   - history: SAN of the moves played before `move`, from the start of the game.
    ///   - phase: the game phase of the move, if known.
    ///   - maxHistory: only the last this-many plies of `history` are shown.
    public static func user(before: Position, move: Move, classification: String?,
                            evalBefore: Eval?, evalAfter: Eval?, tags: [LineTag],
                            refutation: [String], best: [String], history: [String],
                            phase: GamePhase? = nil, maxPlies: Int = 8, maxHistory: Int = 24) -> String {
        let mover = before.turn
        let after = before.applyingUnchecked(move)
        var out: [String] = []
        out.append("Position before the move (FEN): \(before.fen)")
        out.append("Side to move: \(mover == .white ? "White" : "Black")" + (phase.map { ", \($0.name.lowercased())" } ?? ""))
        let num = "\(before.fullmove)\(mover == .white ? "." : "\u{2026}")"
        out.append("Move played: \(num) \(before.san(move))" + (classification.map { " (\($0))" } ?? ""))
        out.append("Position after it (FEN): \(after.fen)")
        if let b = evalBefore, let a = evalAfter {
            out.append("Evaluation from the mover's point of view (for your understanding, don't quote it): \(pov(b, mover)) before, \(pov(a, mover)) after")
        }
        if !tags.isEmpty { out.append("Tags: " + tags.map(\.text).joined(separator: "; ")) }
        let ref = after.numberedLine(fromUCI: refutation, maxPlies: maxPlies)
        if !ref.isEmpty { out.append("Engine line after the move played (refutation or threat): \(ref)") }
        let bst = before.numberedLine(fromUCI: best, maxPlies: maxPlies)
        if !bst.isEmpty { out.append("Engine's better line instead: \(bst)") }
        let shown = Array(history.suffix(maxHistory))
        out.append("Game so far: " + (history.isEmpty ? "(start of game)"
            : (shown.count < history.count ? "\u{2026} " : "") + numbered(shown, endingBefore: before)))
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

    static func numbered(_ sans: [String], endingBefore pos: Position) -> String {
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
