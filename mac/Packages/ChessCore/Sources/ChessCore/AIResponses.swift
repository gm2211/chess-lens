import Foundation

/// Lenient JSON extraction for model answers: tolerates code fences, preambles and trailing prose.
public enum AIJSON {
    /// The first balanced `{...}` object in `text`, decoded. Nil if there is none or it doesn't parse.
    public static func object(in text: String) -> [String: Any]? {
        let chars = Array(text.unicodeScalars)
        var start = 0
        while let open = chars[start...].firstIndex(of: "{") {
            var depth = 0, inString = false, escaped = false
            var end: Int?
            for i in open..<chars.count {
                let c = chars[i]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    continue
                }
                if c == "\"" { inString = true } else if c == "{" { depth += 1 } else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
            }
            guard let end else { return nil }
            var s = String.UnicodeScalarView(); s.append(contentsOf: chars[open...end])
            if let d = String(s).data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return obj }
            start = open + 1
        }
        return nil
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func strings(_ v: Any?) -> [String] {
        if let a = v as? [Any] { return a.compactMap { string($0) } }
        return string(v).map { [$0] } ?? []
    }

    /// Case-insensitive key lookup, also accepting snake_case ("what_went_wrong" for "whatWentWrong").
    static func value(_ o: [String: Any], _ key: String) -> Any? {
        if let v = o[key] { return v }
        let want = key.lowercased()
        return o.first { $0.key.lowercased().replacingOccurrences(of: "_", with: "") == want }?.value
    }
}

/// The AI coach's explanation of one critical moment, written to teach the idea behind it.
public struct MomentLesson: Equatable, Sendable {
    public var concept: String?          // "King stuck in the centre"
    public var idea: String?             // why the concept matters here
    public var whatWentWrong: String?    // what the player likely thought vs what was true
    public var betterIdea: String?       // the better plan, with the engine move as evidence
    public var rule: String?             // rule of thumb / how to spot it next time
    /// Plain-text answer when the model didn't return JSON.
    public var plain: String?

    public init(concept: String? = nil, idea: String? = nil, whatWentWrong: String? = nil, betterIdea: String? = nil,
                rule: String? = nil, plain: String? = nil) {
        self.concept = concept; self.idea = idea; self.whatWentWrong = whatWentWrong
        self.betterIdea = betterIdea; self.rule = rule; self.plain = plain
    }

    public static func parse(_ text: String) -> MomentLesson? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard let o = AIJSON.object(in: t) else { return MomentLesson(plain: stripFences(t)) }
        let l = MomentLesson(concept: AIJSON.string(AIJSON.value(o, "concept")),
                             idea: AIJSON.string(AIJSON.value(o, "idea")),
                             whatWentWrong: AIJSON.string(AIJSON.value(o, "whatWentWrong")),
                             betterIdea: AIJSON.string(AIJSON.value(o, "betterIdea")),
                             rule: AIJSON.string(AIJSON.value(o, "rule")))
        return l.isEmpty ? MomentLesson(plain: stripFences(t)) : l
    }

    var isEmpty: Bool { [concept, idea, whatWentWrong, betterIdea, rule, plain].allSatisfy { $0 == nil } }

    /// Applies `f` to every prose field (the concept name too).
    public func mapText(_ f: (String) -> String?) -> MomentLesson {
        MomentLesson(concept: concept.flatMap(f), idea: idea.flatMap(f), whatWentWrong: whatWentWrong.flatMap(f),
                     betterIdea: betterIdea.flatMap(f), rule: rule.flatMap(f), plain: plain.flatMap(f))
    }
}

/// The AI summary of a whole game, framed around what to learn from it.
public struct GameLesson: Equatable, Sendable {
    /// A cited move with the reason it shows the idea, and what to point at on the board after it.
    public struct Example: Equatable, Sendable {
        public static let maxArrows = 3
        public static let maxSquares = 4

        public var move: String          // "11. Bxb5+"
        public var why: String?          // one sentence tying this move to the concept
        public var arrows: [Arrow]       // drawn on the position after the move; visual only, not moves
        public var squares: [Square]     // highlighted on the position after the move

        public struct Arrow: Equatable, Sendable {
            public var from: Square
            public var to: Square
            public init(from: Square, to: Square) { self.from = from; self.to = to }
            /// "b5e8" (also "b5-e8", "b5 e8", "B5E8"); nil unless two different valid squares.
            public init?(_ text: String) {
                let t = text.lowercased().filter { $0.isLetter || $0.isNumber }
                guard t.count == 4, let f = Sq.parse(String(t.prefix(2))), let to = Sq.parse(String(t.suffix(2))), f != to
                else { return nil }
                self.from = f; self.to = to
            }
            public var uci: String { Sq.name(from) + Sq.name(to) }
        }

        public init(move: String, why: String? = nil, arrows: [Arrow] = [], squares: [Square] = []) {
            self.move = move; self.why = why
            self.arrows = Self.unique(arrows, max: Self.maxArrows)
            self.squares = Self.unique(squares, max: Self.maxSquares)
        }

        /// Reads either `{"move", "why", "arrows", "squares"}` or the older plain move string ("14. Qh5").
        /// Arrows and squares that aren't valid squares are dropped.
        static func parse(_ v: Any) -> Example? {
            if let d = v as? [String: Any] {
                guard let move = AIJSON.string(AIJSON.value(d, "move") ?? AIJSON.value(d, "ref") ?? AIJSON.value(d, "san"))
                else { return nil }
                let arrows = parseArrows(AIJSON.value(d, "arrows"))
                let squares = AIJSON.strings(AIJSON.value(d, "squares"))
                    .compactMap { Sq.parse($0.lowercased().trimmingCharacters(in: .whitespaces)) }
                return Example(move: move, why: AIJSON.string(AIJSON.value(d, "why")), arrows: arrows, squares: squares)
            }
            return AIJSON.string(v).map { Example(move: $0) }
        }

        private static func unique<T: Equatable>(_ xs: [T], max: Int) -> [T] {
            var out: [T] = []
            for x in xs where !out.contains(x) { out.append(x) }
            return Array(out.prefix(max))
        }
    }

    public struct Concept: Equatable, Sendable {
        public var name: String
        public var explanation: String
        public var examples: [Example]
        /// The narrated walkthrough of the idea across the game, in game order (see `StoryStep`).
        public var story: [StoryStep]
        /// The cited move references, e.g. "14. Qh5".
        public var moves: [String] { examples.map(\.move) }
        public init(name: String, explanation: String, examples: [Example] = [], story: [StoryStep] = []) {
            self.name = name; self.explanation = explanation; self.examples = examples; self.story = story
        }
        public init(name: String, explanation: String, moves: [String]) {
            self.init(name: name, explanation: explanation, examples: moves.map { Example(move: $0) })
        }
    }
    public struct Exercise: Equatable, Sendable {
        public var title: String
        public var fromMove: String?     // the critical position, e.g. "23...Nf6"
        public var task: String
        public var concept: String?
        public init(title: String, fromMove: String? = nil, task: String, concept: String? = nil) {
            self.title = title; self.fromMove = fromMove; self.task = task; self.concept = concept
        }
    }

    public var headline: String?
    public var story: String?
    public var concepts: [Concept] = []
    public var white: String?
    public var black: String?
    public var turningPoint: Example?
    public var lessons: [String] = []
    public var exercises: [Exercise] = []
    /// The game's story as 4-6 ordered beats (see `Beat`); empty for lessons written before beats existed.
    public var beats: [Beat] = []

    public init(headline: String? = nil, story: String? = nil, concepts: [Concept] = [], white: String? = nil,
                black: String? = nil, turningPoint: Example? = nil, lessons: [String] = [], exercises: [Exercise] = [],
                beats: [Beat] = []) {
        self.headline = headline; self.story = story; self.concepts = concepts; self.white = white
        self.black = black; self.turningPoint = turningPoint; self.lessons = lessons; self.exercises = exercises
        self.beats = beats
    }

    /// Parses the model's JSON; anything else becomes the story so the user still sees the text.
    public static func parse(_ text: String) -> GameLesson? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard let o = AIJSON.object(in: t) else { return GameLesson(story: stripFences(t)) }
        var g = GameLesson()
        g.headline = AIJSON.string(AIJSON.value(o, "headline"))
        g.story = AIJSON.string(AIJSON.value(o, "story")) ?? AIJSON.string(AIJSON.value(o, "arc"))
        g.white = AIJSON.string(AIJSON.value(o, "white"))
        g.black = AIJSON.string(AIJSON.value(o, "black"))
        g.turningPoint = AIJSON.value(o, "turningPoint").flatMap(Example.parse)
        g.lessons = Array(AIJSON.strings(AIJSON.value(o, "lessons") ?? AIJSON.value(o, "takeaways")).prefix(3))
        for c in (AIJSON.value(o, "concepts") as? [Any] ?? []).prefix(4) {
            if let d = c as? [String: Any], let name = AIJSON.string(AIJSON.value(d, "name")) {
                // "examples" (current) or "moves" (older answers: plain strings, or objects).
                let raw = AIJSON.value(d, "examples") ?? AIJSON.value(d, "moves")
                let items: [Any] = raw as? [Any] ?? raw.map { [$0] } ?? []
                let steps = (AIJSON.value(d, "story") as? [Any] ?? AIJSON.value(d, "steps") as? [Any] ?? [])
                    .compactMap(StoryStep.parse)
                g.concepts.append(Concept(name: name, explanation: AIJSON.string(AIJSON.value(d, "explanation")) ?? "",
                                          examples: items.compactMap(Example.parse), story: steps))
            } else if let s = AIJSON.string(c) {
                g.concepts.append(Concept(name: s, explanation: ""))
            }
        }
        for e in (AIJSON.value(o, "exercises") as? [Any] ?? []).prefix(3) {
            guard let d = e as? [String: Any], let task = AIJSON.string(AIJSON.value(d, "task")) else { continue }
            g.exercises.append(Exercise(title: AIJSON.string(AIJSON.value(d, "title")) ?? "Exercise",
                                        fromMove: AIJSON.string(AIJSON.value(d, "fromMove")),
                                        task: task, concept: AIJSON.string(AIJSON.value(d, "concept"))))
        }
        g.beats = (AIJSON.value(o, "beats") as? [Any] ?? []).prefix(10).compactMap(Beat.parse)
        if g == GameLesson() { return GameLesson(story: stripFences(t)) }
        return g
    }

    /// Grounds the lesson against the game: prose sentences citing moves not in `allowed` are dropped (see
    /// `Grounding.clean`; moves left only unverified are returned), move references that aren't in `line` are
    /// removed, and an example's "why" loses any sentence citing an unsupported move. Examples are put in game order.
    /// Story steps are grounded too (see `groundedStory`); a concept without a story gets one made of its examples.
    public func grounded(allowed: Set<String>, line: LessonLine) -> (lesson: GameLesson, unverified: [String]) {
        var unverified: [String] = []
        func c(_ s: String?) -> String? {
            guard let s else { return nil }
            let r = Grounding.clean(s, allowed: allowed)
            for m in r.unverified where !unverified.contains(m) { unverified.append(m) }
            return r.text
        }
        func ex(_ e: Example) -> (Example, Int)? {
            guard let ply = line.ply(of: e.move), !GameLesson.StoryStep.isStartRef(e.move) else { return nil }
            var out = e
            out.why = e.why.flatMap { w in
                let p = Grounding.prune(w, allowed: allowed).text
                return p.isEmpty ? nil : p
            }
            return (out, ply)
        }
        var out = GameLesson(headline: c(headline), story: c(story), white: c(white), black: c(black))
        out.turningPoint = turningPoint.flatMap(ex)?.0
        out.concepts = concepts.map { concept in
            let examples = concept.examples.compactMap(ex).enumerated()
                .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
            var g = Concept(name: c(concept.name) ?? concept.name, explanation: c(concept.explanation) ?? "",
                            examples: examples)
            g.story = Self.groundedStory(concept.story, allowed: allowed, line: line)
            if g.story.isEmpty { g.story = g.synthesizedStory(plies: line.ply(of:)) }
            return g
        }
        // Cards follow the game: by the earliest ply of any example or story step (concepts with none go last).
        func first(_ c: Concept) -> Int {
            let plies = c.examples.compactMap { line.ply(of: $0.move) } + c.story.compactMap(\.ply)
            return plies.min() ?? Int.max
        }
        out.concepts = out.concepts.enumerated().sorted { (first($0.element), $0.offset) < (first($1.element), $1.offset) }.map(\.element)
        out.lessons = lessons.compactMap { c($0) }
        out.exercises = exercises.map {
            Exercise(title: c($0.title) ?? $0.title, fromMove: $0.fromMove.flatMap { line.ply(of: $0) != nil ? $0 : nil },
                     task: c($0.task) ?? $0.task, concept: $0.concept)
        }
        out.beats = Self.groundedBeats(beats, allowed: allowed, line: line)
        return (out, unverified)
    }

    /// Story steps whose `at` is in the line, in game order (ties keep the model's order), at most `maxSteps`.
    /// A step's `line` is cut at its first illegal move; its narration loses sentences citing moves that are neither
    /// allowed nor in its own line, and a step left with nothing to say is dropped.
    public static func groundedStory(_ steps: [StoryStep], allowed: Set<String>, line: LessonLine) -> [StoryStep] {
        var kept: [(StoryStep, Int, Int)] = []
        for (i, s) in steps.enumerated() {
            guard let ply = line.ply(of: s.at), let pos = line.position(atPly: ply) else { continue }
            let demo = LessonLine.legalPrefix(s.line, from: pos)
            let demoSAN = pos.sanLine(fromUCI: demo)
            let say = Grounding.prune(s.say, allowed: allowed.union(Grounding.allowed(demoSAN))).text
            guard !say.isEmpty else { continue }
            kept.append((StoryStep(at: s.at, say: say, circles: s.circles, arrows: s.arrows, line: demo,
                                   pause: s.pause, ply: ply), ply, i))
        }
        return kept.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.prefix(StoryStep.maxSteps).map(\.0)
    }
}

/// Removes surrounding ``` fences from a plain-text answer.
func stripFences(_ s: String) -> String {
    var lines = s.components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.hasPrefix("```") == true { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
