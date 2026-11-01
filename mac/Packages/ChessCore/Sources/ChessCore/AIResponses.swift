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
                let arrows = (AIJSON.value(d, "arrows") as? [Any] ?? []).compactMap { a -> Arrow? in
                    if let s = AIJSON.string(a) { return Arrow(s) }
                    if let o = a as? [String: Any], let f = AIJSON.string(AIJSON.value(o, "from")),
                       let t = AIJSON.string(AIJSON.value(o, "to")) { return Arrow(f + t) }
                    return nil
                }
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
        /// The cited move references, e.g. "14. Qh5".
        public var moves: [String] { examples.map(\.move) }
        public init(name: String, explanation: String, examples: [Example] = []) {
            self.name = name; self.explanation = explanation; self.examples = examples
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

    public init(headline: String? = nil, story: String? = nil, concepts: [Concept] = [], white: String? = nil,
                black: String? = nil, turningPoint: Example? = nil, lessons: [String] = [], exercises: [Exercise] = []) {
        self.headline = headline; self.story = story; self.concepts = concepts; self.white = white
        self.black = black; self.turningPoint = turningPoint; self.lessons = lessons; self.exercises = exercises
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
                g.concepts.append(Concept(name: name, explanation: AIJSON.string(AIJSON.value(d, "explanation")) ?? "",
                                          examples: items.compactMap(Example.parse)))
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
        if g == GameLesson() { return GameLesson(story: stripFences(t)) }
        return g
    }

    /// Grounds the lesson against the game: prose sentences citing moves not in `allowed` are dropped (see
    /// `Grounding.clean`; moves left only unverified are returned), move references `resolves` rejects are removed,
    /// and an example's "why" loses any sentence citing an unsupported move.
    public func grounded(allowed: Set<String>, resolves: (String) -> Bool) -> (lesson: GameLesson, unverified: [String]) {
        var unverified: [String] = []
        func c(_ s: String?) -> String? {
            guard let s else { return nil }
            let r = Grounding.clean(s, allowed: allowed)
            for m in r.unverified where !unverified.contains(m) { unverified.append(m) }
            return r.text
        }
        func ex(_ e: Example) -> Example? {
            guard resolves(e.move) else { return nil }
            var out = e
            out.why = e.why.flatMap { w in
                let p = Grounding.prune(w, allowed: allowed).text
                return p.isEmpty ? nil : p
            }
            return out
        }
        var out = GameLesson(headline: c(headline), story: c(story), white: c(white), black: c(black))
        out.turningPoint = turningPoint.flatMap(ex)
        out.concepts = concepts.map {
            Concept(name: c($0.name) ?? $0.name, explanation: c($0.explanation) ?? "", examples: $0.examples.compactMap(ex))
        }
        out.lessons = lessons.compactMap { c($0) }
        out.exercises = exercises.map {
            Exercise(title: c($0.title) ?? $0.title, fromMove: $0.fromMove.flatMap { resolves($0) ? $0 : nil },
                     task: c($0.task) ?? $0.task, concept: $0.concept)
        }
        return (out, unverified)
    }
}

/// Removes surrounding ``` fences from a plain-text answer.
func stripFences(_ s: String) -> String {
    var lines = s.components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.hasPrefix("```") == true { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
