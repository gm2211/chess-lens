import Foundation
import ChessCore

/// The game's story beats and the guided walkthrough over them (see `BeatWalkthrough`).
extension AppModel {
    /// The reviewed line, for resolving beats, with the node of each position (index 0 = the line's start).
    private func reviewedLine() -> (line: LessonLine, path: [Int])? {
        let path = review.path.filter { game.nodes.indices.contains($0) }
        guard path.count > 1 else { return nil }
        let start = game.nodes[path[0]].position
        let sans = path.dropFirst().map { game.nodes[$0].san }
        return (LessonLine(start: start, sans: Array(sans), firstPly: game.nodes[path[1]].ply), path)
    }

    /// The review's critical moments, as the fallback beats take them.
    private func beatMoments() -> [BeatMoment] {
        review.momentPicks().compactMap { pick in
            let id = review.path[pick.index]
            guard let pid = game.nodes[id].parent, let move = game.nodes[id].move, let e = review.entries[id] else { return nil }
            let prev = review.entries[pid]
            return BeatMoment(ply: game.nodes[id].ply, side: game.nodes[pid].position.turn, severity: e.cls?.severity ?? 0,
                              classification: e.cls?.name ?? "turning point",
                              best: prev?.best == move.uci ? nil : prev?.best, reply: e.pv.first)
        }
    }

    /// The story of the reviewed game: the AI lesson's beats, or beats made from the review (and whatever lesson
    /// there is) when it has none. Each with its node and, at an error, its question. Empty without a review.
    func storySteps() -> [BeatWalkthrough.Step] {
        guard review.hasResults, !review.running, let (line, path) = reviewedLine() else { return [] }
        var lesson: GameLesson?
        if case .done(let g, _)? = review.lesson.state { lesson = g }
        let beats = StoryBeats.beats(lesson: lesson, moments: beatMoments(), line: line)
        return beats.compactMap { b in
            guard let ply = b.ply ?? line.ply(of: b.at) else { return nil }
            let i = ply - line.firstPly + 1
            guard path.indices.contains(i) else { return nil }
            let id = path[i]
            return BeatWalkthrough.Step(beat: b, nodeID: id, quiz: quiz(at: id))
        }
    }

    /// "Find a better move" at `id` when the move leading there was an error by the side that played it.
    private func quiz(at id: Int) -> BeatWalkthrough.Quiz? {
        guard let e = review.entries[id], e.cls?.isError == true, let pid = game.nodes[id].parent,
              let move = game.nodes[id].move, let prev = review.entries[pid], let best = prev.best, best != move.uci,
              game.nodes[pid].position.move(fromUCI: best) != nil else { return nil }
        return BeatWalkthrough.Quiz(parentID: pid, side: game.nodes[pid].position.turn, best: best, bestEval: prev.eval,
                                    bestLine: prev.pv, played: move.uci, refutation: e.pv)
    }

    /// Opens the guided walkthrough at beat `index` (clicking the open beat again closes it).
    func startWalkthrough(at index: Int = 0) {
        guard canPlayLessons, !hidesEvaluation else { return }
        if let w = walkthrough {
            if w.index == index { closeLesson() } else { w.go(to: index) }
            return
        }
        let steps = storySteps()
        guard steps.indices.contains(index) else { return }
        clearLessonFocus()
        lessonPlayer = nil
        let w = BeatWalkthrough(steps: steps, app: self)
        walkthrough = w
        w.start(at: index)
    }

    /// A move made on the board: a try at the open question, otherwise a real move.
    func boardMove(_ m: Move) {
        if let w = walkthrough, w.acceptsMove { w.submit(m); return }
        play(m)
    }

    /// Engine lines and arrows stay hidden while a question is open, so they don't give the answer away.
    var quizHidesEngine: Bool { walkthrough?.hidesEngine ?? false }
}
