import Foundation

/// A critical moment as handed to the summary prompt. The engine picked it; the model explains it.
public struct SummaryMoment: Sendable, Equatable {
    public var ply: Int                 // 1 = White's first move
    public var label: String            // "23\u{2026}Nf6"
    public var side: Side
    public var classification: String   // "blunder", "mistake", "inaccuracy"
    public var phase: GamePhase?
    public var evalBefore: Eval
    public var evalAfter: Eval
    public var tags: [String]
    public var fenBefore: String
    public var refutation: String       // numbered SAN, from the position after the move
    public var best: String             // numbered SAN, from the position before it

    public init(ply: Int, label: String, side: Side, classification: String, phase: GamePhase?, evalBefore: Eval,
                evalAfter: Eval, tags: [String], fenBefore: String, refutation: String, best: String) {
        self.ply = ply; self.label = label; self.side = side; self.classification = classification; self.phase = phase
        self.evalBefore = evalBefore; self.evalAfter = evalAfter; self.tags = tags; self.fenBefore = fenBefore
        self.refutation = refutation; self.best = best
    }
}

/// Everything the summary prompt is built from.
public struct SummaryFacts: Sendable {
    public var white: String?
    public var black: String?
    public var whiteElo: String?
    public var blackElo: String?
    public var event: String?
    public var result: String?
    public var opening: String?         // "Sicilian Defense (B90)"
    public var start: Position
    public var moves: [String]          // SAN of the reviewed line
    public var evals: [Eval?]           // White's view, after each move (same count as `moves`)
    public var accuracy: [Side: Double]
    public var phases: [Side: [GamePhase: PhaseStat]]
    public var phaseStarts: [GamePhase: Int]   // first ply of each phase reached
    public var moments: [SummaryMoment]        // worst first

    public init(white: String? = nil, black: String? = nil, whiteElo: String? = nil, blackElo: String? = nil,
                event: String? = nil, result: String? = nil, opening: String? = nil, start: Position = .start,
                moves: [String], evals: [Eval?], accuracy: [Side: Double] = [:],
                phases: [Side: [GamePhase: PhaseStat]] = [:], phaseStarts: [GamePhase: Int] = [:],
                moments: [SummaryMoment] = []) {
        self.white = white; self.black = black; self.whiteElo = whiteElo; self.blackElo = blackElo
        self.event = event; self.result = result; self.opening = opening; self.start = start
        self.moves = moves; self.evals = evals; self.accuracy = accuracy; self.phases = phases
        self.phaseStarts = phaseStarts; self.moments = moments
    }

    /// Reads the PGN headers of `game`.
    public mutating func setHeaders(from game: Game) {
        white = PGN.meaningful(game.header("White")); black = PGN.meaningful(game.header("Black"))
        whiteElo = PGN.meaningful(game.header("WhiteElo")); blackElo = PGN.meaningful(game.header("BlackElo"))
        event = PGN.meaningful(game.header("Event"))
        result = game.header("Result").flatMap { $0 == "*" ? nil : $0 } ?? (game.result == "*" ? nil : game.result)
        let name = PGN.meaningful(game.header("Opening")), eco = PGN.meaningful(game.header("ECO"))
        opening = name.map { n in eco.map { "\(n) (\($0))" } ?? n } ?? eco
    }
}

/// Prompt for the AI's lesson on a whole game. Pure, so it can be tested.
public enum SummaryPrompt {
    public static func system(tool: Bool) -> String {
        """
        You are a friendly chess coach turning a finished game into a short lesson for an improving player. \
        The engine already found the critical moments; your job is to explain the ideas behind them in plain English \
        so the player gets better. No move-by-move recap, no evaluation numbers, little notation.
        Reply with only a JSON object:
        {"headline": "1 sentence: the result and the story of the game",
        "story": "2-3 sentences: how the opening went, where the game turned, how it was won or lost",
        "concepts": [{"name": "2-5 words, e.g. king safety, loose pieces, trading when ahead", "explanation": "1-2 sentences: what it means and how it showed up here", "examples": [\(example("a game move that clearly shows the concept, like 11. Bxb5+ or 23...Nf6"))], "story": [\(storyStep)]}],
        "white": "1 sentence on White's play, naming the strongest and weakest phase",
        "black": "1 sentence on Black's play, the same way",
        "turningPoint": \(example("the move where the game turned, like 23...Nf6")),
        "lessons": ["a habit to build, phrased as an instruction"],
        "exercises": [{"title": "a few words", "fromMove": "a critical move ref; the position before it is the puzzle", "task": "what to find, e.g. Find a move that keeps your king safe", "concept": "the concept it trains"}],
        "beats": [\(beat)]}
        Give 2-4 concepts (causes, not moves), 1-3 examples per concept, at most 3 lessons, 2-3 exercises. \
        Cite only moves from the data or engine results, written as in the data (23...Nf6).
        The player clicks an example, sees the board after that move and reads its why, so pick moves that plainly \
        show the concept on the board, not just moves from the same phase (for "moving the same piece twice", cite \
        that piece's second move, not another piece's developing move). Write the why as teaching about this move, \
        e.g. "Black's 6th move and still only one minor piece out; White already has four." Arrows (from and to \
        square, like "b5e8") and squares point at what the why describes on the board after the move: the pinned \
        piece, the loose piece, the open file, the exposed king. Leave them out when nothing helps.
        Each concept's story is a short narrated walkthrough the app plays on the board like a video lesson, 3-7 steps \
        in game order: the setup (how the problem started), the key moment or moments, the consequence, then the rule \
        to remember. Each step shows the position after its "at" move ("start" for before move 1) while "say" is read \
        aloud, so write "say" as speech: one or two short, warm sentences, no notation beyond the move being shown. \
        Use "circles" for the pieces or squares "say" talks about, "arrows" for attacks, pins and plans, and "line" \
        (legal UCI moves from that position, at most 6) to act out what should have happened or what the threat was; \
        the board animates those moves and then returns to the game. Every step should point at something.
        The beats are the game's story told in 4-6 ordered steps, the outline the player walks through first: \
        usually the setup, the slip, the turning point, the punishment and the finish, with an idea beat when one \
        concept explains the game. Each beat shows the position after its "at" move. "slip", "turning" and "punish" \
        beats must point at the real errors in the critical moments: a slip or turning beat's "at" is the error \
        itself (the player will be asked to find the better move there, so explain why the engine's better move \
        works), a punish beat's "at" is the reply that exploited it. Write for a club player: vivid but concrete, \
        built around threats, plans and ideas, never evaluation numbers. The headline is one short sentence; the \
        rule is a memorable rule of thumb.
        Give each slip and turning beat a "script": the scene the app acts out on the board like a GothamChess \
        video, 6-12 steps (leave it out on other beats; the app writes those). It starts on the position before the \
        beat's move, the question. In order: the stakes; ask what the player would play (that step has "ask": true \
        and plays nothing; the player tries a move there); the game move; "But..." and the refutation, 2-4 moves ending \
        on the punchline (the piece lost, the fork, the mate); "rewind": "root" and "So instead..." with the better \
        move and its idea in one sentence (the idea, not an evaluation); then "rewind": "game" and "And in the \
        game...". "play" holds SAN moves from the scene's current position, at most 2 per step, played while "say" is read \
        (bundle a forced recapture: "takes, takes"). Write "say" as speech: one idea, 4-14 words, moves the way \
        people say them ("queen b3", "knight takes f7"), the threat named in plain English as the move lands \
        ("Queen b3. Now b7 and f7 are both hanging."), connectors that vary ("and now", "but wait", "what's the \
        problem?", "here's the point"), a rhetorical question or two, light humour welcome, no numbers.
        Keep the whole answer under 1200 words.
        """ + (tool ? "\n" + EngineTool.instructions : "")
    }

    /// The JSON shape of one example: a concept's cited move, or the turning point.
    static func example(_ move: String) -> String {
        #"{"move": ""# + move + #"", "why": "1 short sentence tying THIS move to the concept, readable while looking at the board after it", "arrows": ["optional, at most 3, from+to squares like b5e8"], "squares": ["optional, at most 4 squares to highlight, like e8"]}"#
    }

    /// The JSON shape of one story beat.
    static let beat = #"{"kind": "setup, slip, turning, punish, finish or idea", "at": "the game move, like 6...Nf6", "title": "2-4 words, like The slip", "headline": "one short sentence", "explain": "2-3 plain sentences built around threats, plans and ideas", "rule": "one memorable rule of thumb", "arrows": ["optional, at most 3, like b5e8"], "circles": ["optional, at most 4 squares, like f6"], "script": [\#(sceneStep)]}"#

    /// The JSON shape of one step of a beat's scene.
    static let sceneStep = #"{"say": "one short spoken line", "play": ["optional, 0-2 SAN moves from the scene's current position, like Qb3"], "rewind": "optional, root or game: jump back before this step", "ask": "optional, true on the step that asks the player", "arrows": ["optional, like b3f7"], "circles": ["optional, like b7"]}"#

    /// The JSON shape of one story step.
    static let storyStep = #"{"at": "the game move whose position is shown, like 6...Nf6, or start", "say": "1-2 short spoken sentences about this position", "circles": ["optional, at most 4 squares to circle, like f6"], "arrows": ["optional, at most 3, like b5e8"], "line": ["optional, at most 6 legal UCI moves to animate from this position, like e1c1"], "pause": "optional seconds to hold, like 1"}"#

    /// - Parameter compact: a shorter prompt for models with a small context (fewer moments, one eval per move, no FENs).
    public static func user(_ f: SummaryFacts, compact: Bool = false) -> String {
        var out: [String] = []
        func player(_ name: String?, _ elo: String?, _ side: String) -> String {
            (name ?? side) + (elo.map { " (\($0))" } ?? "")
        }
        out.append("White: \(player(f.white, f.whiteElo, "White")). Black: \(player(f.black, f.blackElo, "Black")).")
        var meta: [String] = []
        if let r = f.result { meta.append("Result: \(r)") }
        if let o = f.opening { meta.append("Opening: \(o)") }
        if let e = f.event, !compact { meta.append("Event: \(e)") }
        if !meta.isEmpty { out.append(meta.joined(separator: ". ") + ".") }
        if f.start.fen != Position.startFEN { out.append("Start position (FEN): \(f.start.fen)") }
        out.append("Moves: " + f.start.numbered(f.moves))
        out.append("Evaluation after each move (pawns, White's view): " + evalSeries(f, everyOther: compact))

        for side in [Side.white, .black] {
            let name = side == .white ? "White" : "Black"
            var parts: [String] = []
            if let a = f.accuracy[side] { parts.append("\(Int(a.rounded()))% accuracy") }
            for ph in GamePhase.allCases {
                guard let s = f.phases[side]?[ph], let a = s.accuracy else { continue }
                var bits = ["\(s.moves) moves"]
                if s.blunders > 0 { bits.append("\(s.blunders) blunder\(s.blunders == 1 ? "" : "s")") }
                if s.mistakes > 0 { bits.append("\(s.mistakes) mistake\(s.mistakes == 1 ? "" : "s")") }
                if s.inaccuracies > 0 && !compact { bits.append("\(s.inaccuracies) inaccurac\(s.inaccuracies == 1 ? "y" : "ies")") }
                parts.append("\(ph.name.lowercased()) \(Int(a.rounded()))% (\(bits.joined(separator: ", ")))")
            }
            if !parts.isEmpty { out.append("\(name): " + parts.joined(separator: "; ")) }
        }
        let starts = GamePhase.allCases.dropFirst().compactMap { ph in
            f.phaseStarts[ph].map { "\(ph.name.lowercased()) from move \(($0 + 1) / 2)" }
        }
        if !starts.isEmpty { out.append("Phases: " + starts.joined(separator: ", ")) }

        let moments = f.moments.prefix(compact ? 3 : 6)
        if moments.isEmpty {
            out.append("Critical moments: none, the engine found no real mistakes.")
        } else {
            out.append("Critical moments (worst first):")
            for m in moments {
                var line = "- \(m.label) by \(m.side == .white ? "White" : "Black"), \(m.classification)"
                if let p = m.phase { line += " in the \(p.name.lowercased())" }
                line += "; eval \(short(m.evalBefore)) to \(short(m.evalAfter))"
                if !m.tags.isEmpty { line += "; " + m.tags.joined(separator: ", ") }
                line += "."
                if !compact { line += " FEN before: \(m.fenBefore)." }
                if !m.refutation.isEmpty { line += " Engine reply: \(m.refutation)." }
                if !m.best.isEmpty { line += " Better was: \(m.best)." }
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// "1. +0.3 +0.2 2. +0.4 ..." (or just the score after each full move when `everyOther`).
    static func evalSeries(_ f: SummaryFacts, everyOther: Bool) -> String {
        var parts: [String] = []
        var number = f.start.fullmove
        var white = f.start.turn == .white
        for (i, e) in f.evals.enumerated() {
            let lastOfMove = !white || i == f.evals.count - 1
            if everyOther {
                if lastOfMove { parts.append("\(number). \(e.map(short) ?? "?")") }
            } else {
                if white { parts.append("\(number).") } else if i == 0 { parts.append("\(number)\u{2026}") }
                parts.append(e.map(short) ?? "?")
            }
            if !white { number += 1 }
            white.toggle()
        }
        return parts.joined(separator: " ")
    }

    /// One decimal in pawns, or "M3" / "-M3", or "#" when the game is over.
    static func short(_ e: Eval) -> String {
        switch e {
        case .cp(let c): String(format: "%+.1f", Double(c) / 100)
        case .mate(let m): m < 0 ? "-M\(-m)" : "M\(m)"
        case .checkmate(let w): w == .white ? "1-0#" : "0-1#"
        }
    }
}
