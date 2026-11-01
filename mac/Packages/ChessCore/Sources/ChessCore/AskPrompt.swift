import Foundation

/// Prompt for "Ask AI": a free-form question about a position or move, answered in plain text.
/// Pure, so it can be tested. Mirrors `CoachPrompt` (teaching style, same data conventions).
public enum AskPrompt {
    /// What the question is about: the position on the board and, if a move led there, that move.
    public struct Subject: Sendable {
        /// The position being asked about (after `move`).
        public var position: Position
        /// The position before `move`, if the position was reached by a move.
        public var before: Position?
        public var move: Move?
        /// e.g. "blunder", "great move"; nil when the move was not reviewed or not noteworthy.
        public var classification: String?
        /// Engine scores from White's point of view: `evalBefore` for `before`, `evalNow` for `position`.
        public var evalBefore: Eval?
        public var evalNow: Eval?
        public var tags: [LineTag]
        /// UCI engine line from `position`, and from `before` (the engine's preferred alternative).
        public var line: [String]
        public var best: [String]
        /// SAN of every move played up to and including `move`.
        public var history: [String]
        public var phase: GamePhase?
        /// Stockfish results run by the app for `position` (and for `before`), shown to the model like tool results.
        public var engine: EngineReport?
        public var engineBefore: EngineReport?

        /// The evaluation (White's point of view) the verdict is computed from: the fresh engine run first.
        public var verdictEval: Eval? { engine?.lines.first?.eval ?? evalNow }

        public init(position: Position, before: Position? = nil, move: Move? = nil, classification: String? = nil,
                    evalBefore: Eval? = nil, evalNow: Eval? = nil, tags: [LineTag] = [], line: [String] = [],
                    best: [String] = [], history: [String] = [], phase: GamePhase? = nil,
                    engine: EngineReport? = nil, engineBefore: EngineReport? = nil) {
            self.position = position; self.before = before; self.move = move; self.classification = classification
            self.evalBefore = evalBefore; self.evalNow = evalNow; self.tags = tags; self.line = line
            self.best = best; self.history = history; self.phase = phase
            self.engine = engine; self.engineBefore = engineBefore
        }
    }

    /// Top engine lines (White's point of view) at a depth, for one position.
    public struct EngineReport: Equatable, Sendable {
        public var lines: [EngineToolLine]
        public var depth: Int
        public init(lines: [EngineToolLine], depth: Int) { self.lines = lines; self.depth = depth }

        /// The report as a tool result would read, and the SAN moves it shows.
        public func text(for position: Position, maxLines: Int = 3) -> (text: String, sans: [String]) {
            EngineTool.result(for: EngineToolRequest(fen: position.fen), start: position, sans: [], position: position,
                              lines: Array(lines.prefix(maxLines)), depth: depth)
        }
    }

    /// One earlier exchange. `context` says where the board was when it was asked ("After 10…cxb5").
    public struct Turn: Equatable, Sendable {
        public var context: String
        public var question: String
        public var answer: String
        public init(context: String, question: String, answer: String) {
            self.context = context; self.question = question; self.answer = answer
        }
    }

    public static let maxHistory = 16, maxTurns = 4, maxAnswerChars = 400
    public static let compactHistory = 8, compactTurns = 2, compactAnswerChars = 200

    public static func system(tool: Bool, compact: Bool = false) -> String {
        let words = compact ? "40 to 100 words" : "40 to 150 words"
        return """
        You are a friendly chess coach answering a player's question about a position or a move in their game. \
        Answer in plain English, like a teacher: explain the ideas and rules of thumb behind the position, not just \
        the moves. Little notation, no evaluation numbers unless the player asks for them. The engine evaluation and \
        the material summary in the data are ground truth: never contradict the engine's verdict and never recount \
        material yourself. If the player's claim agrees with the engine, confirm it and explain why; if it disagrees, \
        say so kindly and explain with the engine lines. Cite only moves from the \
        data, from engine results, or that the player named, and never say a piece is on a square unless the FEN \
        shows it. Reply in plain text (short paragraphs, no JSON, no headings). Keep it to \(words) unless the \
        player asks for more. If the question isn't about chess, say so briefly. If the player names a move that the \
        data says is not legal, don't stop at saying so: kindly point out what they probably meant (often the engine's \
        top move by the same piece, or a legal move to or near that square) and answer about that move.
        """ + (tool ? "\nBefore suggesting any move or plan that is not in the engine lines you were given, check it with the engine tool.\n" + EngineTool.instructions : "")
    }

    /// "After 10…cxb5 · White to move" / "Start of the game · White to move".
    public static func contextLabel(position: Position, before: Position?, move: Move?) -> String {
        let turn = position.turn == .white ? "White" : "Black"
        guard let before, let move else { return "Start of the game \u{00B7} \(turn) to move" }
        let num = "\(before.fullmove)\(before.turn == .white ? "." : "\u{2026}")"
        return "After \(num)\(before.san(move)) \u{00B7} \(turn) to move"
    }

    /// Suggested questions for the empty chat. `bestAlternative` is the engine's SAN move from the position before
    /// the move played (when it differs from it); the "mistake" question only appears for a reviewed move.
    public static func starters(classification: String?, isError: Bool, bestAlternative: String?) -> [String] {
        var out: [String] = []
        if classification != nil { out.append(isError ? "Why was this a mistake?" : "Why was this a good move?") }
        out.append("What's the plan here?")
        out.append("What should I be careful about?")
        if let b = bestAlternative { out.append("Why not \(b) instead?") }
        return out
    }

    /// Moves written in the player's questions and the earlier answers. The model may repeat them in its reply.
    public static func citedMoves(in texts: [String]) -> [String] {
        texts.flatMap { Grounding.citations(in: $0).map(\.san) }
    }

    public static func user(_ s: Subject, turns: [Turn], question: String, compact: Bool = false) -> String {
        let pos = s.position
        let mover = pos.turn == .white ? "White" : "Black"
        var out: [String] = []
        out.append("Position (FEN): \(pos.fen)")
        out.append("Side to move: \(mover)" + (s.phase.map { ", \($0.name.lowercased())" } ?? ""))
        out.append("Material (counted by the app, ground truth): " + pos.materialSummary.promptText)
        if let e = s.verdictEval {
            out.append("Engine evaluation (Stockfish, ground truth): \(EngineVerdict.line(e))")
        }
        if let r = s.engine {
            out.append("Engine results for the position above:\n" + r.text(for: pos, maxLines: compact ? 2 : 3).text)
        }
        if let before = s.before, let move = s.move {
            let num = "\(before.fullmove)\(before.turn == .white ? "." : "\u{2026}")"
            out.append("Move just played: \(num) \(before.san(move))" + (s.classification.map { " (\($0))" } ?? ""))
            if !compact { out.append("Position before that move (FEN): \(before.fen)") }
            if !compact, let r = s.engineBefore {
                out.append("Engine results for the position before that move:\n" + r.text(for: before, maxLines: 3).text)
            }
            let played = before.turn
            if let b = s.evalBefore, let a = s.evalNow {
                out.append("Evaluation from the point of view of the side that just moved (for your understanding, don't quote it): "
                           + "\(CoachPrompt.pov(b, played)) before, \(CoachPrompt.pov(a, played)) after")
            }
            if !compact, !s.tags.isEmpty { out.append("Tags: " + s.tags.map(\.text).joined(separator: "; ")) }
            let now = pos.numberedLine(fromUCI: s.line, maxPlies: compact ? 4 : 8)
            if !now.isEmpty { out.append("Engine line from here: \(now)") }
            let bst = before.numberedLine(fromUCI: s.best, maxPlies: compact ? 4 : 8)
            if !bst.isEmpty { out.append("Engine's preferred line instead of the move just played: \(bst)") }
        } else if let e = s.evalNow, s.engine == nil {
            out.append("Evaluation from the point of view of the side to move (for your understanding, don't quote it): \(CoachPrompt.pov(e, pos.turn))")
            let now = pos.numberedLine(fromUCI: s.line, maxPlies: compact ? 4 : 8)
            if !now.isEmpty { out.append("Engine line from here: \(now)") }
        }
        let limit = compact ? compactHistory : maxHistory
        let shown = Array(s.history.suffix(limit))
        out.append("Game so far: " + (s.history.isEmpty ? "(start of game)"
            : (shown.count < s.history.count ? "\u{2026} " : "") + CoachPrompt.numbered(shown, endingBefore: pos)))

        let kept = Array(turns.suffix(compact ? compactTurns : maxTurns))
        if !kept.isEmpty {
            let cap = compact ? compactAnswerChars : maxAnswerChars
            out.append("\n--- Earlier in this conversation ---")
            for t in kept {
                out.append("Player (board then: \(t.context)): \(t.question)\nYou: \(truncate(t.answer, cap))")
            }
            out.append("--- End of earlier conversation ---")
        }
        for note in illegalMoveNotes(question: question, subject: s) { out.append("\nNote: " + note.text) }
        out.append("\nPlayer's question about the position above: \(question.trimmingCharacters(in: .whitespacesAndNewlines))")
        return out.joined(separator: "\n")
    }

    /// Cuts at a word boundary and adds an ellipsis.
    static func truncate(_ s: String, _ limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        let cut = String(t.prefix(limit))
        let words = cut.split(separator: " ", omittingEmptySubsequences: true).dropLast()
        return (words.isEmpty ? cut : words.joined(separator: " ")) + "\u{2026}"
    }
}
