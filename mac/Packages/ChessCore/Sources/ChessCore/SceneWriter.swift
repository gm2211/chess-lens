import Foundation

/// Writes a beat's scene when the lesson has none, in the order a video lesson tells a mistake: the stakes, "what
/// would you play?", the game move, "but wait" and the refutation to its punchline, a rewind to the better move and
/// its idea, then back to the game. Other beats get a short narrated look at the position. Deterministic: the
/// connectors vary with the beat's ply.
public enum SceneWriter {
    typealias Step = GameLesson.SceneStep
    typealias Arrow = GameLesson.Example.Arrow

    /// An error the player is asked about, as the review found it. Moves are UCI.
    public struct Moment: Sendable, Equatable {
        /// The position before the error: the question.
        public var root: Position
        public var played: String
        /// The engine's line after the move played.
        public var refutation: [String]
        public var best: String?
        public var classification: String?

        public init(root: Position, played: String, refutation: [String], best: String?, classification: String? = nil) {
            self.root = root; self.played = played; self.refutation = refutation; self.best = best
            self.classification = classification
        }

        var severity: Int {
            switch classification?.lowercased() {
            case "blunder": 3
            case "mistake": 2
            default: 1
            }
        }
    }

    /// Plies of the refutation shown before the scene rewinds.
    static let maxRefutation = 4

    /// The beat's scene: the error walk-through when `moment` is given, else a short look at the beat's position
    /// (`lastMove` = the game move that led there, from `before`).
    public static func scene(beat: GameLesson.Beat, moment: Moment?, lastMove: Move? = nil,
                             before: Position? = nil) -> [GameLesson.SceneStep] {
        if let moment, let s = errorScene(beat, moment), !s.isEmpty { return s }
        return infoScene(beat, lastMove: lastMove, before: before)
    }

    // MARK: Errors

    static func errorScene(_ beat: GameLesson.Beat, _ m: Moment) -> [Step]? {
        let root = m.root, side = root.turn
        guard let playedMove = root.move(fromUCI: m.played) else { return nil }
        let name = StoryBeats.name(side)
        var seed = beat.ply ?? root.fullmove
        func pick(_ xs: [String]) -> String { defer { seed += 1 }; return xs[abs(seed) % xs.count] }
        var steps: [Step] = []

        // The stakes, then the question.
        let stakes = switch m.severity {
        case 3: "One move here decides the game."
        case 2: "One natural move here goes wrong."
        default: "There's a small trap here."
        }
        steps.append(Step(say: pick(["\(name) to move.", "Move \(root.fullmove), \(name) to play.", "Here it's \(name)'s move."])
                          + " " + stakes))
        steps.append(Step(say: pick(["What would you play?", "What's your move here?", "Take a second. What would you play?"]), ask: true))

        // The tempting move.
        let played = root.spoken(playedMove)
        steps.append(Step(say: pick(["In the game, \(name) went \(played).", "\(name) played \(played). Looks natural, right?",
                                     "The game move: \(played). Seems reasonable."]), moves: [m.played]))

        // "But wait": the refutation, a ply or two per step, to its punchline.
        var p = root.applyingUnchecked(playedMove)
        let ref = moves(m.refutation, from: p)
        let startGap = p.material(side.opposite) - p.material(side)
        if ref.isEmpty {
            steps.append(Step(say: "But that's \(StoryBeats.article(m.classification ?? "mistake")) \(m.classification ?? "mistake").",
                              pause: 1.0))
        } else {
            var i = 0
            var opener: String? = pick(["But wait.", "But there's a problem.", "What's the problem?"])
            var noted = false
            while i < min(ref.count, maxRefutation) {
                // The first ply alone; after it, the defender's reply and the punisher's follow-up together, while
                // the follow-up still threatens or takes something.
                let group = i == 0 ? [ref[0]] : Array(ref[i..<min(i + 2, ref.count, maxRefutation)])
                if i > 0 {
                    // [the defender's reply, the punisher's follow-up]: a lone reply or a quiet follow-up ends the line.
                    guard group.count == 2 else { break }
                    let d = describe(group[1], p.applyingUnchecked(group[0]))
                    if d.note == nil, !d.captured { break }
                }
                var texts: [String] = [], arrows: [Arrow] = [], circles: [Square] = []
                var punch = false
                noted = false
                for (k, mv) in group.enumerated() {
                    let byPunisher = p.turn == side.opposite
                    let recapture = k > 0 && mv.to == group[k - 1].to && p.board[mv.to] != nil
                    let d = describe(mv, p)
                    if recapture {
                        texts[texts.count - 1] = String(texts[texts.count - 1].dropLast()) + ", \(d.spoken)."
                    } else if byPunisher {
                        let lead = k > 0 ? pick(["And now ", "Then ", "Now "]) + d.spoken : capitalized(d.spoken)
                        texts.append(lead + ".")
                    } else {
                        texts.append(pick(["\(name) tries \(d.spoken).", "\(name) answers \(d.spoken).", "\(capitalized(d.spoken))."]))
                    }
                    if byPunisher, let note = d.note { texts.append(note); noted = true }
                    if byPunisher { arrows = d.arrows; circles = d.circles }
                    p = p.applyingUnchecked(mv)
                    let gain = p.material(side.opposite) - p.material(side) - startGap
                    let next = i + k + 1 < ref.count ? ref[i + k + 1] : nil
                    let recaptured = next.map { $0.to == mv.to } ?? false
                    if p.isCheckmate || (byPunisher && gain >= 1 && !recaptured && d.captured) { punch = true }
                }
                i += group.count
                steps.append(Step(say: ([opener].compactMap { $0 } + texts).joined(separator: " "), moves: group.map(\.uci),
                                  arrows: arrows, circles: circles))
                opener = nil
                if punch { break }
            }
            // The punchline lands on the last step of the line.
            if let end = punchline(p, side: side, startGap: startGap, severity: m.severity, noted: noted) {
                steps[steps.count - 1].say += " " + end
            }
            steps[steps.count - 1].pause = 1.0
        }

        // Rewind: the better move and its idea.
        if let b = m.best, let bm = root.move(fromUCI: b) {
            steps.append(Step(say: pick(["So instead, \(root.spoken(bm)).", "Rewind. Instead, \(root.spoken(bm)).",
                                         "Let's go back. Instead: \(root.spoken(bm))."]), moves: [b], rewind: .root))
            let r = reason(bm, root, punish: ref.first, punishFrom: root.applyingUnchecked(playedMove))
            let lead = pick(["Here's the point: ", "The idea? ", "Why? "])
            steps.append(Step(say: lead + (lead.hasSuffix("? ") ? capitalized(r.text) : r.text), arrows: r.arrows,
                              circles: r.circles, pause: 0.6))
        }

        // Back to the game.
        var back = pick(["And in the game, \(name) went \(played).", "Back to the game, and \(played).",
                         "But in the game, it was \(played)."])
        if let rule = beat.rule { back += " Remember: " + LessonPlaylist.trimmedSentence(rule) }
        steps.append(Step(say: back, arrows: beat.arrows, circles: beat.circles, rewind: .game))
        return Array(steps.prefix(Step.maxSteps))
    }

    /// The closing line of a refutation: mate, the material won, or how it stands (nil when the last move's threat
    /// already makes the point).
    static func punchline(_ p: Position, side: Side, startGap: Int, severity: Int, noted: Bool) -> String? {
        let opp = StoryBeats.name(side.opposite)
        if p.isCheckmate { return "Game over." }
        let gain = p.material(side.opposite) - p.material(side) - startGap
        let what: String? = switch gain {
        case 8...: "the queen"
        case 5...7: "a rook"
        case 3...4: "a whole piece"
        case 2: "two pawns"
        case 1: "a pawn"
        default: nil
        }
        if let what { return "\(opp) wins \(what)." }
        if noted { return nil }
        return switch severity {
        case 3: "And \(opp) is winning."
        case 2: "And \(opp) is clearly better."
        default: "And \(opp) gets the better game."
        }
    }

    /// Why the better move works, in one sentence. `punish` is the reply that refuted the game move (from
    /// `punishFrom`, the position after it).
    static func reason(_ best: Move, _ root: Position, punish: Move?, punishFrom: Position)
        -> (text: String, arrows: [Arrow], circles: [Square]) {
        let f = root.features(best)
        let after = root.applyingUnchecked(best)
        if f.mate { return ("it's checkmate on the spot!", [], []) }
        if !f.hanging.isEmpty {
            let targets = Array(f.hanging.prefix(3))
            let list = list(targets.map(after.spokenTarget))
            return (f.check ? "check, and it hits \(list) too." : "it hits \(list).", attackArrows(best.to, targets, after), targets)
        }
        if let c = f.captured { return ("it simply takes the \(c.type.name).", [], [best.to]) }
        if let r = punish {
            if let again = after.move(fromUCI: r.uci) {
                let g = after.features(again)
                if g.hanging.isEmpty, !g.mate, g.mateThreat == nil, g.captured == nil {
                    return ("now \(after.spoken(again)) doesn't hit anything.", [], [])
                }
                // The squares the refutation hit that are covered now.
                let before = punishFrom.features(r).hanging
                let covered = before.filter { !g.hanging.contains($0) && after.board[$0] != nil }
                if !covered.isEmpty {
                    return ("it covers \(list(covered.prefix(2).map(after.spokenTarget))) before \(StoryBeats.name(root.turn.opposite)) gets there.",
                            [], Array(covered.prefix(2)))
                }
            } else if let p = punishFrom.board[r.from] {
                return ("now \(p.type == .pawn ? "the pawn push" : p.type.name) to \(Sq.name(r.to)) isn't even possible.", [], [])
            }
        }
        if let sq = f.mateThreat { return ("it threatens mate on \(Sq.name(sq)).", [], [sq]) }
        if f.check { return ("it comes with check and keeps the initiative.", [], []) }
        return ("it keeps \(StoryBeats.name(root.turn)) out of trouble.", [], [])
    }

    // MARK: Other beats

    static func infoScene(_ beat: GameLesson.Beat, lastMove: Move?, before: Position?) -> [Step] {
        var steps = [Step(say: beat.headline, arrows: beat.arrows, circles: beat.circles)]
        if let m = lastMove, let before, before.isLegal(m), [.slip, .turning, .punish, .finish].contains(beat.kind) {
            let d = describe(m, before)
            if let note = d.note {
                steps.append(Step(say: "Look at \(d.spoken). \(note)", arrows: d.arrows.isEmpty ? beat.arrows : d.arrows,
                                  circles: d.circles.isEmpty ? beat.circles : d.circles))
            }
        }
        let sentences = beat.explain.map(Grounding.sentences) ?? []
        var i = 0
        while i < sentences.count, steps.count < 4 {
            let chunk = sentences[i..<min(i + 2, sentences.count)]
            steps.append(Step(say: chunk.joined(separator: " "), arrows: beat.arrows, circles: beat.circles))
            i += chunk.count
        }
        steps[steps.count - 1].pause = 1.0
        return steps
    }

    // MARK: Moves

    /// One move as narrated: how it's said, what it threatens, and what to point at.
    struct Described {
        var spoken: String
        var note: String?
        var arrows: [Arrow]
        var circles: [Square]
        var captured: Bool
    }

    static func describe(_ m: Move, _ pos: Position) -> Described {
        let f = pos.features(m)
        let after = pos.applyingUnchecked(m)
        let hanging = Array(f.hanging.prefix(3))
        let names = hanging.map(after.spokenTarget)
        var note: String?
        if f.mate {
            note = "Game over."
        } else if f.check, let t = hanging.first {
            note = "A fork: the king and \(after.spokenTarget(t))."
        } else if hanging.count >= 2 {
            note = "Now \(list(names)) are \(hanging.count == 2 ? "both" : "all") hanging."
        } else if let sq = f.mateThreat {
            note = "And now there's a threat of mate on \(Sq.name(sq))."
        } else if let t = hanging.first {
            note = after.board[t]?.type == .pawn ? "Now the pawn on \(Sq.name(t)) hangs." : "Now \(names[0]) is hanging."
        } else if let p = f.promotion {
            note = "A brand new \(p.name)."
        }
        var circles = hanging
        if let sq = f.mateThreat, hanging.isEmpty { circles.append(sq) }
        return Described(spoken: pos.spoken(m), note: note, arrows: attackArrows(m.to, hanging, after), circles: circles,
                         captured: f.captured != nil)
    }

    /// "the threat clause" of a reply, for one-line explanations: "hits b7 and f7", "is checkmate".
    public static func threatClause(_ m: Move, from pos: Position) -> String {
        let f = pos.features(m)
        let after = pos.applyingUnchecked(m)
        let names = f.hanging.prefix(3).map(after.spokenTarget)
        if f.mate { return "is checkmate" }
        if names.count >= 2 { return "hits \(list(names))" }
        if f.check, let t = names.first { return "forks the king and \(t)" }
        if f.check { return "comes with check" }
        if let sq = f.mateThreat { return "threatens mate on \(Sq.name(sq))" }
        if let c = f.captured { return c.type == .pawn ? "takes on \(Sq.name(m.to))" : "takes the \(c.type.name) on \(Sq.name(m.to))" }
        if let t = names.first { return "hits \(t)" }
        return "punishes it"
    }

    /// Arrows from the piece on `from` to the targets it attacks directly.
    static func attackArrows(_ from: Square, _ targets: [Square], _ pos: Position) -> [Arrow] {
        let hits = Set(pos.attackedSquares(from: from))
        return targets.filter { hits.contains($0) && $0 != from }.prefix(GameLesson.Beat.maxArrows).map { Arrow(from: from, to: $0) }
    }

    /// The legal prefix of `uci` from `pos`.
    static func moves(_ uci: [String], from pos: Position) -> [Move] {
        var p = pos, out: [Move] = []
        for u in uci {
            guard let m = p.move(fromUCI: u), p.isLegal(m) else { break }
            out.append(m); p = p.applyingUnchecked(m)
        }
        return out
    }

    /// "b7 and f7", "a, b and c".
    static func list(_ xs: [String]) -> String {
        switch xs.count {
        case 0: ""
        case 1: xs[0]
        default: xs.dropLast().joined(separator: ", ") + " and " + xs.last!
        }
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
