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
    public struct Concept: Equatable, Sendable {
        public var name: String
        public var explanation: String
        public var moves: [String]       // move references, e.g. "14. Qh5"
        public init(name: String, explanation: String, moves: [String] = []) {
            self.name = name; self.explanation = explanation; self.moves = moves
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
    public var turningPoint: String?
    public var lessons: [String] = []
    public var exercises: [Exercise] = []

    public init(headline: String? = nil, story: String? = nil, concepts: [Concept] = [], white: String? = nil,
                black: String? = nil, turningPoint: String? = nil, lessons: [String] = [], exercises: [Exercise] = []) {
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
        g.turningPoint = AIJSON.string(AIJSON.value(o, "turningPoint"))
        g.lessons = Array(AIJSON.strings(AIJSON.value(o, "lessons") ?? AIJSON.value(o, "takeaways")).prefix(3))
        for c in (AIJSON.value(o, "concepts") as? [Any] ?? []).prefix(4) {
            if let d = c as? [String: Any], let name = AIJSON.string(AIJSON.value(d, "name")) {
                g.concepts.append(Concept(name: name, explanation: AIJSON.string(AIJSON.value(d, "explanation")) ?? "",
                                          moves: AIJSON.strings(AIJSON.value(d, "moves"))))
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
}

/// Removes surrounding ``` fences from a plain-text answer.
func stripFences(_ s: String) -> String {
    var lines = s.components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.hasPrefix("```") == true { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
