import Foundation

extension GameLesson {
    /// One beat of the game's story, the outline of the guided review: a game position, a short title, a one-line
    /// headline, a plain explanation and a rule of thumb, with what to point at on the board.
    public struct Beat: Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case setup, slip, turning, punish, finish, idea

            public var defaultTitle: String {
                switch self {
                case .setup: "The setup"
                case .slip: "The slip"
                case .turning: "The turning point"
                case .punish: "The punishment"
                case .finish: "The finish"
                case .idea: "The big idea"
                }
            }

            /// Lenient: "turning point" → turning, "mistake" → slip, "ending" → finish, unknown → idea.
            static func parse(_ s: String?) -> Kind {
                let t = (s ?? "").lowercased().filter(\.isLetter)
                if let k = Kind(rawValue: t) { return k }
                if t.hasPrefix("turn") || t == "turningpoint" { return .turning }
                if ["mistake", "error", "blunder", "inaccuracy", "slipup"].contains(t) { return .slip }
                if t.hasPrefix("punish") || t == "refutation" || t == "exploit" { return .punish }
                if ["end", "ending", "finale", "conclusion", "result", "mate", "checkmate"].contains(t) { return .finish }
                if ["opening", "intro", "start", "beginning", "set"].contains(t) { return .setup }
                return .idea
            }
        }

        public static let maxBeats = 6
        public static let maxArrows = 3
        public static let maxCircles = 4

        public var kind: Kind
        /// The game move whose resulting position the beat shows ("6...Nf6"), or "start".
        public var at: String
        public var title: String
        public var headline: String
        public var explain: String?
        public var rule: String?
        public var arrows: [Example.Arrow]
        public var circles: [Square]
        /// Ply of the position after `at` (0 = before White's first move). Set by grounding; nil until then.
        public var ply: Int?
        /// The AI's scene for the beat (see `SceneStep`); empty when it wrote none, and the app writes one.
        public var script: [SceneStep]

        public init(kind: Kind, at: String, title: String? = nil, headline: String, explain: String? = nil,
                    rule: String? = nil, arrows: [Example.Arrow] = [], circles: [Square] = [], ply: Int? = nil,
                    script: [SceneStep] = []) {
            self.kind = kind; self.at = at
            let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.title = t.isEmpty ? kind.defaultTitle : t
            self.headline = headline; self.explain = explain; self.rule = rule
            self.arrows = Self.unique(arrows, max: Self.maxArrows)
            self.circles = Self.unique(circles, max: Self.maxCircles)
            self.ply = ply
            self.script = Array(script.prefix(SceneStep.maxSteps))
        }

        /// Whether the scene starts on the position before `at` (the question at an error) rather than after it.
        public var asksAtError: Bool { kind == .slip || kind == .turning }

        /// What the narrator reads: headline, explanation, rule.
        public var narration: String {
            [headline, explain, rule.map { "Rule of thumb: " + $0 }].compactMap { $0 }
                .map(LessonPlaylist.trimmedSentence).filter { !$0.isEmpty }.joined(separator: " ")
        }

        static func parse(_ v: Any) -> Beat? {
            guard let d = v as? [String: Any] else { return nil }
            let headline = AIJSON.string(AIJSON.value(d, "headline") ?? AIJSON.value(d, "summary"))
            let explain = AIJSON.string(AIJSON.value(d, "explain") ?? AIJSON.value(d, "explanation") ?? AIJSON.value(d, "why"))
            guard headline != nil || explain != nil else { return nil }
            let at = AIJSON.string(AIJSON.value(d, "at") ?? AIJSON.value(d, "move")) ?? "start"
            let circles = AIJSON.strings(AIJSON.value(d, "circles") ?? AIJSON.value(d, "squares"))
                .compactMap { Sq.parse($0.lowercased().trimmingCharacters(in: .whitespaces)) }
            return Beat(kind: Kind.parse(AIJSON.string(AIJSON.value(d, "kind") ?? AIJSON.value(d, "type"))), at: at,
                        title: AIJSON.string(AIJSON.value(d, "title")), headline: headline ?? "",
                        explain: explain, rule: AIJSON.string(AIJSON.value(d, "rule")),
                        arrows: Example.parseArrows(AIJSON.value(d, "arrows")), circles: circles,
                        script: (AIJSON.value(d, "script") as? [Any] ?? AIJSON.value(d, "scene") as? [Any] ?? [])
                            .prefix(SceneStep.maxSteps * 2).compactMap(SceneStep.parse))
        }

        private static func unique<T: Equatable>(_ xs: [T], max: Int) -> [T] {
            var out: [T] = []
            for x in xs where !out.contains(x) { out.append(x) }
            return Array(out.prefix(max))
        }
    }

    /// Beats whose `at` is in the line, in game order (ties keep the model's order; one beat per position), at most
    /// `Beat.maxBeats`. Prose loses sentences citing moves not in `allowed`; a beat left with nothing to say is
    /// dropped, and a missing headline is taken from the explanation's first sentence. A script is replayed from the
    /// position before `at` for slip and turning beats, after it otherwise (see `BeatScene.grounded`).
    public static func groundedBeats(_ beats: [Beat], allowed: Set<String>, line: LessonLine) -> [Beat] {
        func prune(_ s: String?) -> String? {
            guard let s else { return nil }
            let p = Grounding.prune(s, allowed: allowed).text
            return p.isEmpty ? nil : p
        }
        var kept: [(Beat, Int, Int)] = []
        var plies = Set<Int>()
        for (i, b) in beats.enumerated() {
            guard let ply = line.ply(of: b.at), line.position(atPly: ply) != nil, !plies.contains(ply) else { continue }
            var explain = prune(b.explain)
            var headline = prune(b.headline)
            if headline == nil, let e = explain {
                let parts = Grounding.sentences(e)
                headline = parts.first
                explain = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : nil
            }
            guard let headline, let game = line.position(atPly: ply) else { continue }
            plies.insert(ply)
            let root = b.asksAtError ? line.position(atPly: ply - 1) ?? game : game
            let script = BeatScene.grounded(b.script, allowed: allowed, root: root, game: game)
            kept.append((Beat(kind: b.kind, at: b.at, title: prune(b.title), headline: headline, explain: explain,
                              rule: prune(b.rule), arrows: b.arrows, circles: b.circles, ply: ply, script: script), ply, i))
        }
        return kept.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.prefix(Beat.maxBeats).map(\.0)
    }
}

/// A critical moment the review found, as the fallback story beats need it.
public struct BeatMoment: Sendable, Equatable {
    public var ply: Int                  // ply of the move (1 = White's first move)
    public var side: Side                // who played it
    public var severity: Int             // 1 inaccuracy, 2 mistake, 3 blunder (0 = not an error)
    public var classification: String    // "mistake"
    public var best: String?             // the engine's better move from the position before (UCI)
    public var reply: String?            // the engine's answer to the move played (UCI)

    public init(ply: Int, side: Side, severity: Int, classification: String, best: String? = nil, reply: String? = nil) {
        self.ply = ply; self.side = side; self.severity = severity; self.classification = classification
        self.best = best; self.reply = reply
    }
}

/// Story beats when the lesson has none (written before beats existed, or no AI at all): made from the review's
/// critical moments and whatever the lesson already says. Deterministic.
public enum StoryBeats {
    public static func fallback(lesson: GameLesson?, moments: [BeatMoment], line: LessonLine) -> [GameLesson.Beat] {
        typealias Beat = GameLesson.Beat
        let lastPly = line.firstPly - 1 + line.positions.count - 1
        guard lastPly >= line.firstPly else { return [] }
        var beats: [(beat: Beat, priority: Int)] = []
        var used = Set<Int>()
        func add(_ b: Beat, _ priority: Int) {
            guard let p = b.ply, !used.contains(p) else { return }
            used.insert(p); beats.append((b, priority))
        }
        let habits = lesson?.lessons.map(LessonPlaylist.trimmedSentence).filter { !$0.isEmpty } ?? []

        // Errors: the worst is the turning point, up to two more are slips.
        let errors = moments.filter { $0.severity > 0 && $0.ply <= lastPly && line.position(atPly: $0.ply) != nil }
            .sorted { ($0.severity, -$0.ply) > ($1.severity, -$1.ply) }
        let picked = Array(errors.prefix(3))
        let worst = picked.first
        for (i, m) in picked.sorted(by: { $0.ply < $1.ply }).enumerated() {
            let turning = m == worst
            let ref = label(ply: m.ply, line: line) ?? ""
            let before = line.position(atPly: m.ply - 1), after = line.position(atPly: m.ply)
            let best = m.best.flatMap { u in before.flatMap { moveLabel(u, from: $0) } }
            let reply = m.reply.flatMap { u in after.flatMap { moveLabel(u, from: $0) } }
            var explain: [String] = []
            if let best { explain.append("Stronger was \(best).") }
            if let reply, let after, let r = m.reply.flatMap(after.move(fromUCI:)) {
                explain.append("After \(display(ref)), \(reply) \(SceneWriter.threatClause(r, from: after)).")
            }
            let arrow = m.reply.flatMap { u in after?.move(fromUCI: u) }.map { GameLesson.Example.Arrow(from: $0.from, to: $0.to) }
            add(Beat(kind: turning ? .turning : .slip, at: ref,
                     headline: "\(name(m.side))'s \(display(ref)) is \(article(m.classification)) \(m.classification).",
                     explain: explain.isEmpty ? nil : explain.joined(separator: " "),
                     rule: habits.indices.contains(i) ? habits[i] : genericRule(severity: m.severity),
                     arrows: arrow.map { [$0] } ?? [], ply: m.ply), turning ? 0 : 1)
        }
        // The punishment: the game move right after the worst error, when it was the engine's answer.
        if let w = worst, let reply = w.reply, let after = line.position(atPly: w.ply), w.ply + 1 <= lastPly,
           let next = line.position(atPly: w.ply + 1), let m = after.move(fromUCI: reply),
           let played = try? after.applying(m), played.fen == next.fen, let ref = label(ply: w.ply + 1, line: line) {
            add(Beat(kind: .punish, at: ref, headline: "\(name(w.side.opposite)) punishes it with \(display(ref)).",
                     rule: "When your opponent slips, look for checks, captures and threats first.", ply: w.ply + 1), 2)
        }
        // The finish.
        if let end = line.positions.last, let ref = label(ply: lastPly, line: line) {
            let mate = end.isCheck && end.legalMoves().isEmpty
            add(Beat(kind: .finish, at: ref, headline: mate ? "Checkmate ends the game." : "The game ends here.",
                     rule: habits.count > picked.count ? habits.last : nil, ply: lastPly), 3)
        }
        // The setup: a few moves before the first beat, or after the opening's first moves.
        let firstBeat = beats.map { $0.beat.ply ?? lastPly }.min() ?? lastPly
        let setupPly = max(line.firstPly - 1, min(line.firstPly - 1 + 10, firstBeat - 2))
        let story = lesson?.story.map(Grounding.sentences) ?? []
        let setupAt = setupPly < line.firstPly ? "start" : (label(ply: setupPly, line: line) ?? "start")
        add(Beat(kind: .setup, at: setupAt, headline: story.first ?? "Both sides bring out their pieces.",
                 explain: story.count > 1 ? story.dropFirst().joined(separator: " ") : nil, ply: setupPly), 4)
        // One idea from the lesson's concepts, at a story step not already covered.
        if let lesson {
            outer: for c in lesson.concepts {
                for s in c.story {
                    guard let p = s.ply ?? line.ply(of: s.at), line.position(atPly: p) != nil, !used.contains(p) else { continue }
                    let title = c.name.split(separator: " ").prefix(4).joined(separator: " ")
                    let head = Grounding.sentences(c.explanation).first ?? s.say
                    add(Beat(kind: .idea, at: s.at, title: title.prefix(1).uppercased() + title.dropFirst(), headline: head,
                             explain: head == s.say ? nil : s.say, arrows: s.arrows, circles: s.circles, ply: p), 5)
                    break outer
                }
            }
        }
        let kept = beats.sorted { $0.priority < $1.priority }.prefix(GameLesson.Beat.maxBeats).map(\.beat)
        return kept.sorted { ($0.ply ?? 0) < ($1.ply ?? 0) }
    }

    /// The lesson's own beats when it has any, else the fallback.
    public static func beats(lesson: GameLesson?, moments: [BeatMoment], line: LessonLine) -> [GameLesson.Beat] {
        if let l = lesson, !l.beats.isEmpty { return l.beats }
        return fallback(lesson: lesson, moments: moments, line: line)
    }

    /// "9...b5" for the move at `ply` (ASCII dots, so `LessonLine.ply(of:)` reads it back).
    public static func label(ply: Int, line: LessonLine) -> String? {
        let i = ply - line.firstPly
        guard line.sans.indices.contains(i), let before = line.position(atPly: ply - 1) else { return nil }
        return "\(before.fullmove)\(before.turn == .white ? ". " : "...")\(line.sans[i])"
    }

    /// "10. Nxb5" (display form) for a UCI move from `pos`.
    public static func moveLabel(_ uci: String, from pos: Position) -> String? {
        guard let san = pos.sanLine(fromUCI: [uci], maxPlies: 1).first else { return nil }
        return display("\(pos.fullmove)\(pos.turn == .white ? ". " : "...")\(san)")
    }

    /// "9...b5" → "9\u{2026}b5" for display.
    public static func display(_ label: String) -> String { label.replacingOccurrences(of: "...", with: "\u{2026}") }

    static func name(_ s: Side) -> String { s == .white ? "White" : "Black" }
    static func article(_ word: String) -> String { word.first.map { "aeiou".contains($0) } == true ? "an" : "a" }

    static func genericRule(severity: Int) -> String {
        switch severity {
        case 3...: "Before every move, check what each enemy piece can capture."
        case 2: "Ask what your opponent wants to do after your move."
        default: "When nothing is forced, improve your worst-placed piece."
        }
    }
}
