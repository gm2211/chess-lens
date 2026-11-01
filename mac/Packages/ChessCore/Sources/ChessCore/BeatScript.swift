import Foundation

extension GameLesson {
    /// One step of a beat's scene, the way a video lesson explains a moment: a spoken line, a few moves played on
    /// top of the scene's current position (never added to the game), what to point at, and where to rewind first.
    public struct SceneStep: Equatable, Sendable {
        /// Where the scene jumps before the step's moves: the beat's question position, or the game's position
        /// after the beat's move.
        public enum Rewind: String, Sendable { case root, game }

        public static let maxMoves = 3
        public static let maxSteps = 14
        public static let maxPause = 4.0

        public var say: String
        /// UCI once validated (see `BeatScene.validated`); as written (SAN or UCI) before.
        public var moves: [String]
        public var arrows: [Example.Arrow]
        public var circles: [Square]
        public var rewind: Rewind?
        /// The scene pauses here for the player's try (hands-free play just holds).
        public var ask: Bool
        /// Extra seconds to hold the step after it is narrated.
        public var pause: Double?

        public init(say: String, moves: [String] = [], arrows: [Example.Arrow] = [], circles: [Square] = [],
                    rewind: Rewind? = nil, ask: Bool = false, pause: Double? = nil) {
            self.say = say; self.moves = moves
            self.arrows = Self.unique(arrows, max: Beat.maxArrows)
            self.circles = Self.unique(circles, max: Beat.maxCircles)
            self.rewind = rewind; self.ask = ask
            self.pause = pause.map { min(max($0, 0), Self.maxPause) }
        }

        /// Lenient: moves as an array or one string ("7. Qb3 Qe7"), rewind as "root"/"question"/"game"/true.
        static func parse(_ v: Any) -> SceneStep? {
            guard let d = v as? [String: Any] else { return nil }
            let say = AIJSON.string(AIJSON.value(d, "say") ?? AIJSON.value(d, "text") ?? AIJSON.value(d, "line")) ?? ""
            let rawMoves = AIJSON.value(d, "moves") ?? AIJSON.value(d, "move") ?? AIJSON.value(d, "play")
            let moves = AIJSON.strings(rawMoves).flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
                .map(Self.stripNumber).filter { !$0.isEmpty }
            let rewind: Rewind? = switch AIJSON.value(d, "rewind") {
            case let b as Bool: b ? .root : nil
            case let s as String:
                switch s.lowercased().filter(\.isLetter) {
                case "game", "actual", "actualgame", "thegame", "back": .game
                case "root", "question", "start", "instead", "true", "yes": .root
                default: nil
                }
            default: nil
            }
            let ask: Bool = switch AIJSON.value(d, "ask") {
            case let b as Bool: b
            case let n as NSNumber: n.boolValue
            case let s as String: ["true", "yes", "1"].contains(s.lowercased())
            default: false
            }
            let pause: Double? = switch AIJSON.value(d, "pause") {
            case let n as NSNumber: n.doubleValue
            case let s as String: Double(s)
            default: nil
            }
            guard !say.isEmpty || !moves.isEmpty || rewind != nil else { return nil }
            let circles = AIJSON.strings(AIJSON.value(d, "circles") ?? AIJSON.value(d, "squares"))
                .compactMap { Sq.parse($0.lowercased().trimmingCharacters(in: .whitespaces)) }
            return SceneStep(say: say, moves: moves, arrows: Example.parseArrows(AIJSON.value(d, "arrows")),
                             circles: circles, rewind: rewind, ask: ask, pause: pause)
        }

        /// "7.Qb3" / "7...Qe7" / "7…Qe7" → the move; a bare "7." → "".
        static func stripNumber(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let i = t.firstIndex(where: { !$0.isNumber }) else { return "" }
            guard i != t.startIndex, ".\u{2026}".contains(t[i]) else { return t }
            return String(t[i...].drop { $0 == "." || $0 == "\u{2026}" })
        }

        private static func unique<T: Equatable>(_ xs: [T], max: Int) -> [T] {
            var out: [T] = []
            for x in xs where !out.contains(x) { out.append(x) }
            return Array(out.prefix(max))
        }
    }
}

/// Checks and replays a beat's scene (see `GameLesson.SceneStep`). Pure.
public enum BeatScene {
    typealias Step = GameLesson.SceneStep

    /// The scene replayed from `root` (`game` = the position after the beat's move): moves become UCI; an illegal
    /// step and everything after it are dropped, except a later step that rewinds to the game (and what follows it,
    /// if legal). At most `SceneStep.maxSteps`.
    public static func validated(_ steps: [GameLesson.SceneStep], root: Position, game: Position) -> [GameLesson.SceneStep] {
        replay(steps, root: root, game: game).map(\.step)
    }

    /// Each valid step with the position its moves start from.
    static func replay(_ steps: [Step], root: Position, game: Position) -> [(step: Step, from: Position)] {
        var out: [(Step, Position)] = []
        var cur = root
        for (i, s) in steps.enumerated() {
            guard out.count < Step.maxSteps else { break }
            let start = s.rewind == .root ? root : s.rewind == .game ? game : cur
            var p = start, ucis: [String] = []
            for raw in s.moves.prefix(Step.maxMoves) {
                let t = Step.stripNumber(raw)
                guard let m = p.move(fromUCI: t.lowercased()) ?? (try? p.parseSAN(t)), let n = try? p.applying(m) else {
                    // Illegal: keep only a later rewind to the game, and what follows it.
                    guard let j = steps.indices.last(where: { $0 > i && steps[$0].rewind == .game }) else { return out }
                    let tail = replay(Array(steps[j...]), root: root, game: game)
                    return Array((out + tail).prefix(Step.maxSteps))
                }
                ucis.append(m.uci); p = n
            }
            var step = s; step.moves = ucis
            out.append((step, start)); cur = p
        }
        return out
    }

    /// SAN of every move the scene plays.
    public static func sans(_ steps: [GameLesson.SceneStep], root: Position, game: Position) -> [String] {
        replay(steps, root: root, game: game).flatMap { $0.from.sanLine(fromUCI: $0.step.moves) }
    }

    /// The scene validated and its text grounded: sentences citing moves neither in `allowed` nor played in the
    /// scene are dropped (spoken moves like "queen b3" are not notation and stay). A step left silent says its
    /// moves aloud, or where it rewinds to; a silent step that does nothing is dropped.
    public static func grounded(_ steps: [GameLesson.SceneStep], allowed: Set<String>, root: Position,
                                game: Position) -> [GameLesson.SceneStep] {
        let played = replay(steps, root: root, game: game)
        let ok = allowed.union(Grounding.allowed(played.flatMap { $0.from.sanLine(fromUCI: $0.step.moves) }))
        return played.compactMap { item -> Step? in
            var s = item.step
            s.say = Grounding.prune(s.say, allowed: ok).text
            if s.say.isEmpty {
                if !s.moves.isEmpty {
                    s.say = LessonPlaylist.trimmedSentence(SceneWriter.capitalized(spoken(s.moves, from: item.from)))
                } else if let r = s.rewind {
                    s.say = r == .root ? "Let's go back." : "Back to the game."
                } else if !s.ask {
                    return nil
                }
            }
            return s
        }
    }

    /// The scene with a question: unchanged when a step already asks, else "What would you play?" goes before the
    /// first move (still on the question position).
    public static func ensuringAsk(_ steps: [GameLesson.SceneStep]) -> [GameLesson.SceneStep] {
        guard !steps.contains(where: \.ask) else { return steps }
        var out = steps
        let i = steps.firstIndex { !$0.moves.isEmpty || $0.rewind != nil } ?? steps.count
        out.insert(Step(say: "What would you play?", ask: true), at: i)
        return Array(out.prefix(Step.maxSteps))
    }

    /// "queen b3, queen e7" for UCI moves from `pos`.
    static func spoken(_ moves: [String], from pos: Position) -> String {
        var p = pos, out: [String] = []
        for u in moves {
            guard let m = p.move(fromUCI: u) else { break }
            out.append(p.spoken(m)); p = p.applyingUnchecked(m)
        }
        return out.joined(separator: ", ")
    }

    /// The position after step `index` of a validated scene.
    public static func position(after index: Int, of steps: [GameLesson.SceneStep], root: Position, game: Position) -> Position {
        var cur = root
        for s in steps.prefix(index + 1) {
            if let r = s.rewind { cur = r == .root ? root : game }
            for u in s.moves { if let m = cur.move(fromUCI: u) { cur = cur.applyingUnchecked(m) } }
        }
        return cur
    }
}
