import Foundation

extension GameLesson {
    /// One beat of a concept's narrated walkthrough: a position from the game, a spoken line about it, what to
    /// circle and point at, and optionally a hypothetical continuation to animate from there.
    public struct StoryStep: Equatable, Sendable {
        public static let maxCircles = 4
        public static let maxArrows = 3
        public static let maxLine = 6
        public static let maxSteps = 7
        public static let maxPause = 6.0

        /// The game move whose resulting position is shown ("6...Nf6"), or "start" for the position before move 1.
        public var at: String
        public var say: String
        public var circles: [Square]
        public var arrows: [Example.Arrow]
        /// UCI moves played on top of the `at` position as a demonstration (never added to the game).
        public var line: [String]
        /// Extra seconds to hold the step after it is narrated.
        public var pause: Double?
        /// The ply of the position shown (0 = before White's first move). Set by grounding; nil until then.
        public var ply: Int?

        public init(at: String, say: String, circles: [Square] = [], arrows: [Example.Arrow] = [], line: [String] = [],
                    pause: Double? = nil, ply: Int? = nil) {
            self.at = at; self.say = say
            self.circles = Self.unique(circles, max: Self.maxCircles)
            self.arrows = Self.unique(arrows, max: Self.maxArrows)
            self.line = Array(line.prefix(Self.maxLine))
            self.pause = pause.map { min(max($0, 0), Self.maxPause) }
            self.ply = ply
        }

        /// Whether `at` names the position before the first move.
        public var isStart: Bool { Self.isStartRef(at) }

        static func isStartRef(_ s: String) -> Bool {
            let t = s.lowercased().trimmingCharacters(in: .whitespaces)
            return ["start", "begin", "beginning", "initial", "0", "before 1", "before move 1"].contains(t)
        }

        static func parse(_ v: Any) -> StoryStep? {
            guard let d = v as? [String: Any],
                  let say = AIJSON.string(AIJSON.value(d, "say") ?? AIJSON.value(d, "text") ?? AIJSON.value(d, "narration"))
            else { return nil }
            let at = AIJSON.string(AIJSON.value(d, "at") ?? AIJSON.value(d, "move")) ?? "start"
            let circles = AIJSON.strings(AIJSON.value(d, "circles") ?? AIJSON.value(d, "squares"))
                .compactMap { Sq.parse($0.lowercased().trimmingCharacters(in: .whitespaces)) }
            let arrows = Example.parseArrows(AIJSON.value(d, "arrows"))
            let line = AIJSON.strings(AIJSON.value(d, "line"))
            let pause: Double? = switch AIJSON.value(d, "pause") {
            case let n as NSNumber: n.doubleValue
            case let s as String: Double(s)
            default: nil
            }
            return StoryStep(at: at, say: say, circles: circles, arrows: arrows, line: line, pause: pause)
        }

        private static func unique<T: Equatable>(_ xs: [T], max: Int) -> [T] {
            var out: [T] = []
            for x in xs where !out.contains(x) { out.append(x) }
            return Array(out.prefix(max))
        }
    }
}

extension GameLesson.Example {
    static func parseArrows(_ v: Any?) -> [Arrow] {
        let items: [Any] = v as? [Any] ?? v.map { [$0] } ?? []
        return items.compactMap { a -> Arrow? in
            if let s = AIJSON.string(a) { return Arrow(s) }
            if let o = a as? [String: Any], let f = AIJSON.string(AIJSON.value(o, "from")),
               let t = AIJSON.string(AIJSON.value(o, "to")) { return Arrow(f + t) }
            return nil
        }
    }
}

/// The reviewed line a lesson is grounded against: its moves, the positions they lead to, and move-reference lookup.
public struct LessonLine: Sendable {
    public let start: Position
    public let sans: [String]
    /// Ply of `sans[0]` (1 = White's first move).
    public let firstPly: Int
    /// positions[0] = `start`, positions[i] = after `sans[i - 1]`. Stops early if a move doesn't replay.
    public let positions: [Position]

    public init(start: Position, sans: [String], firstPly: Int = 1) {
        self.start = start; self.sans = sans; self.firstPly = firstPly
        var ps = [start]
        var p = start
        for s in sans {
            guard let m = try? p.parseSAN(s), let n = try? p.applying(m) else { break }
            ps.append(n); p = n
        }
        positions = ps
    }

    /// Ply of the position after the referenced move ("start" = the position before the line).
    public func ply(of ref: String) -> Int? {
        if GameLesson.StoryStep.isStartRef(ref) { return firstPly - 1 }
        return Grounding.ply(of: ref, line: sans, firstPly: firstPly)
    }

    public func position(atPly ply: Int) -> Position? {
        let i = ply - firstPly + 1
        return positions.indices.contains(i) ? positions[i] : nil
    }

    /// The legal prefix of `moves` (UCI, or SAN as a fallback) from `pos`, as UCI.
    public static func legalPrefix(_ moves: [String], from pos: Position, max: Int = GameLesson.StoryStep.maxLine) -> [String] {
        var p = pos
        var out: [String] = []
        for raw in moves.prefix(max) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let m = p.move(fromUCI: t.lowercased()) ?? (try? p.parseSAN(t))
            guard let m, let next = try? p.applying(m) else { break }
            out.append(m.uci); p = next
        }
        return out
    }
}

extension GameLesson.Concept {
    /// A story made of the concept's examples, one step each, for answers written before stories existed.
    public func synthesizedStory(plies: (String) -> Int?) -> [GameLesson.StoryStep] {
        let sorted = examples.compactMap { e in plies(e.move).map { (e, $0) } }.sorted { $0.1 < $1.1 }
        return sorted.prefix(GameLesson.StoryStep.maxSteps).enumerated().map { i, pair in
            let (e, ply) = pair
            let say = e.why ?? (i == 0 && !explanation.isEmpty ? explanation : "Here is \(name.lowercased()) in the game.")
            return GameLesson.StoryStep(at: e.move, say: say, circles: e.squares, arrows: e.arrows, ply: ply)
        }
    }
}
