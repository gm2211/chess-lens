import Foundation

/// One step of the "play the full review" playlist: a story step plus the concept it belongs to.
public struct PlayableStep: Equatable, Sendable {
    public var step: GameLesson.StoryStep
    /// The concept title shown while the step plays ("Overview" / "Habits to build" for the intro / outro).
    public var concept: String
    public init(step: GameLesson.StoryStep, concept: String) { self.step = step; self.concept = concept }
    public var ply: Int { step.ply ?? 0 }
}

/// Builds the playlist for the whole review: an intro, every concept's story merged in game order, the turning
/// point, and a closing step with the habits to build.
public enum LessonPlaylist {
    public static let introTitle = "Overview"
    public static let outroTitle = "Habits to build"
    public static let turningPointTitle = "Turning point"

    public static func build(lesson: GameLesson, line: LessonLine) -> [PlayableStep] {
        // 1. Concept steps, each with a ply, merged in game order (ties keep concept order, then story order).
        var items: [(step: PlayableStep, ply: Int, order: Int)] = []
        var order = 0
        for concept in lesson.concepts {
            let title = capitalized(concept.name)
            for s in concept.story {
                guard let ply = s.ply ?? line.ply(of: s.at), line.position(atPly: ply) != nil else { continue }
                var step = s; step.ply = ply
                items.append((PlayableStep(step: step, concept: title), ply, order)); order += 1
            }
        }
        // 2. Turning point, unless some step already shows that position.
        if let tp = lesson.turningPoint, let ply = line.ply(of: tp.move), line.position(atPly: ply) != nil,
           !GameLesson.StoryStep.isStartRef(tp.move), !items.contains(where: { $0.ply == ply }) {
            let say = tp.why ?? "This is the turning point of the game, at \(tp.move)."
            let step = GameLesson.StoryStep(at: tp.move, say: say, circles: tp.squares, arrows: tp.arrows, ply: ply)
            items.append((PlayableStep(step: step, concept: turningPointTitle), ply, order))
        }
        items.sort { ($0.ply, $0.order) < ($1.ply, $1.order) }

        // 3. Drop identical consecutive-or-repeated steps (same position and same words).
        var seen = Set<String>()
        var middle: [PlayableStep] = []
        for it in items {
            let key = "\(it.ply)|\(it.step.step.say)"
            if seen.insert(key).inserted { middle.append(it.step) }
        }

        var out: [PlayableStep] = []
        if let intro = introText(lesson) {
            let ply = line.firstPly - 1
            out.append(PlayableStep(step: GameLesson.StoryStep(at: "start", say: intro, ply: ply), concept: introTitle))
        }
        out += middle
        if let outro = outroText(lesson), line.positions.count > 1 {
            let ply = line.firstPly - 1 + line.positions.count - 1
            let at = line.sans.indices.contains(line.positions.count - 2) ? line.sans[line.positions.count - 2] : "start"
            out.append(PlayableStep(step: GameLesson.StoryStep(at: at, say: outro, ply: ply), concept: outroTitle))
        }
        return out
    }

    static func introText(_ g: GameLesson) -> String? {
        let head = g.headline.map { trimmedSentence($0) }
        let story = g.story.flatMap { firstSentence($0) }
        let parts = [head, story].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func outroText(_ g: GameLesson) -> String? {
        let habits = g.lessons.map { trimmedSentence($0) }.filter { !$0.isEmpty }
        guard !habits.isEmpty else { return nil }
        return "Habits to build. " + habits.joined(separator: " ")
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The text with exactly one terminal punctuation mark.
    static func trimmedSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return "" }
        return ".!?".contains(last) ? t : t + "."
    }

    /// The first sentence (up to a period/!/? followed by a space), so the intro stays one line.
    static func firstSentence(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var prev: Character = " "
        for (i, ch) in zip(t.indices, t) {
            let next = t.index(after: i)
            if ".!?".contains(ch), !prev.isNumber, next == t.endIndex || t[next] == " " {
                return String(t[...i])
            }
            prev = ch
        }
        return trimmedSentence(t)
    }
}
