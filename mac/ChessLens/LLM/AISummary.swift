import Foundation
import Observation
import ChessCore

/// The AI's lesson on the whole reviewed game: concepts, habits, story and exercises. Owned by `ReviewModel`,
/// so it is cleared (and a request in flight is cancelled) whenever the review restarts or another game loads.
@Observable @MainActor
final class AISummary {
    enum State: Equatable {
        case loading
        /// `unverified`: moves still cited without support after the retry (shown with a marker).
        case done(GameLesson, unverified: [String])
        case needsSignIn
        case failed(String)
    }

    private(set) var state: State?
    /// Shown while the lesson restarts after a model switch ("Switched to Grok \u{2014} writing again\u{2026}").
    private(set) var switchNote: String?

    var phase: AIJobPhase {
        switch state {
        case nil: .idle
        case .loading?: .running
        case .failed?: .failed
        case .needsSignIn?: .needsSignIn
        case .done?: .done
        }
    }

    /// The reviewed line the lesson was written about, for resolving move references.
    @ObservationIgnored private var path: [Int] = []
    @ObservationIgnored private var line: [String] = []
    @ObservationIgnored private var firstPly = 1
    @ObservationIgnored private(set) var lessonLine = LessonLine(start: .start, sans: [])
    @ObservationIgnored private var task: Task<Void, Never>?
    private let hub: AIHub

    init(hub: AIHub = .shared) { self.hub = hub }

    func reset() {
        task?.cancel(); task = nil
        state = nil; switchNote = nil
        path = []; line = []; lessonLine = LessonLine(start: .start, sans: [])
    }

    /// Shown when a review finishes with no AI provider set up.
    func markNeedsSetup() { if state == nil { state = .needsSignIn } }

    /// Starts writing the lesson; the returned task finishes when it is done (or failed).
    @discardableResult
    func generate(game: Game, review: ReviewModel, force: Bool = false) -> Task<Void, Never>? {
        guard force || state != .loading, review.path.count > 1 else { return nil }
        task?.cancel()
        if !force { switchNote = nil }
        let input = Self.input(game: game, review: review)
        path = review.path
        line = input.facts.moves
        firstPly = game.nodes[review.path[1]].ply
        lessonLine = LessonLine(start: input.facts.start, sans: line, firstPly: firstPly)
        state = .loading
        let t = Task { await run(input) }
        task = t
        return t
    }

    /// The provider or model changed: a lesson in flight, failed or waiting on a sign-in starts over with the new one.
    /// A finished lesson is left alone.
    func providerChanged(game: Game, review: ReviewModel) {
        guard AIRetry.restartsOnSwitch(phase), !review.running else { return }
        if generate(game: game, review: review, force: true) != nil {
            switchNote = "Switched to \(hub.selected.displayName) \u{2014} writing again\u{2026}"
        }
    }

    /// Node id of the position a story step shows: after its move, or the line's first position for "start".
    func node(forStep step: GameLesson.StoryStep) -> Int? {
        guard let ply = step.ply ?? lessonLine.ply(of: step.at) else { return nil }
        let i = ply - firstPly + 1
        return path.indices.contains(i) ? path[i] : nil
    }

    /// Node id of the move a reference like "23...Nf6" points to, if it is in the reviewed line.
    func node(for ref: String) -> Int? {
        guard let ply = Grounding.ply(of: ref, line: line, firstPly: firstPly) else { return nil }
        let i = ply - firstPly + 1
        return path.indices.contains(i) ? path[i] : nil
    }

    private func run(_ input: Input) async {
        do {
            if !hub.isReady { await hub.refresh(hub.selected) }
            guard hub.isReady else { switchNote = nil; state = .needsSignIn; return }
            // Apple's on-device model has a small context window: start compact there.
            let compactFirst = hub.selected == .apple
            let answer: GroundedAnswer
            do {
                answer = try await attempt(input, compact: compactFirst, tool: true)
            } catch where !compactFirst && AIToolLoop.isContextLimit(error) {
                answer = try await attempt(input, compact: true, tool: false)
            }
            if Task.isCancelled { return }
            switchNote = nil
            guard let lesson = GameLesson.parse(answer.text) else { state = .failed("The model returned no text."); return }
            let (grounded, unverified) = clean(lesson, allowed: answer.allowed)
            state = .done(grounded, unverified: unverified)
        } catch {
            // A cancelled run leaves the state to whoever cancelled it (a restart may already have set a new one).
            if Task.isCancelled { return }
            switchNote = nil
            if error is CancellationError || (error as? LLMError) == .canceled {
                if state == .loading { state = nil }
            } else if let e = error as? LLMError, e.needsSignIn {
                state = .needsSignIn
                await hub.refresh(hub.selected)
            } else {
                state = .failed(hub.failureText(for: error))
            }
        }
    }

    private func attempt(_ input: Input, compact: Bool, tool: Bool) async throws -> GroundedAnswer {
        try await AIToolLoop.run(hub: hub, system: SummaryPrompt.system(tool: tool),
                                 prompt: SummaryPrompt.user(input.facts, compact: compact),
                                 maxTokens: 1800, allowed: input.allowed, tool: tool, timeout: .lesson)
    }

    /// Grounds every prose field (see `GameLesson.grounded`) and drops move references that aren't in the game.
    private func clean(_ g: GameLesson, allowed: Set<String>) -> (GameLesson, [String]) {
        let r = g.grounded(allowed: allowed, line: lessonLine)
        return (r.lesson, r.unverified)
    }

    // MARK: Input

    struct Input: Sendable {
        var facts: SummaryFacts
        /// Normalized SAN the answer may cite: the game and the moments' engine lines.
        var allowed: Set<String>
    }

    static func input(game: Game, review: ReviewModel) -> Input {
        let path = review.path.filter { game.nodes.indices.contains($0) }
        let ids = Array(path.dropFirst())
        let start = game.nodes[path[0]].position
        let s = review.summary(game: game)
        var accuracy: [Side: Double] = [:]
        accuracy[.white] = s.white.accuracy
        accuracy[.black] = s.black.accuracy
        let phases = review.phases(game: game)
        var starts: [GamePhase: Int] = [:]
        for id in path { if let p = phases[id], starts[p] == nil { starts[p] = game.nodes[id].ply + 1 } }

        var sans = ids.map { game.nodes[$0].san }
        var moments: [SummaryMoment] = []
        for pick in review.momentPicks().sorted(by: { $0.score > $1.score }) {
            let id = review.path[pick.index]
            guard let pid = game.nodes[id].parent, let move = game.nodes[id].move,
                  let e = review.entries[id], let prev = review.entries[pid] else { continue }
            let before = game.nodes[pid].position, after = game.nodes[id].position
            let tags = before.lineTags(played: move, refutation: e.pv, best: prev.pv, evalAfter: e.eval).map(\.text)
            let isBest = prev.best == move.uci
            moments.append(SummaryMoment(
                ply: game.nodes[id].ply,
                label: "\(before.fullmove)\(before.turn == .white ? ". " : "\u{2026}")\(game.nodes[id].san)",
                side: before.turn, classification: e.cls?.name ?? "turning point", phase: phases[pid],
                evalBefore: prev.eval, evalAfter: e.eval, tags: tags, fenBefore: before.fen,
                refutation: after.numberedLine(fromUCI: e.pv, maxPlies: 6),
                best: isBest ? "" : before.numberedLine(fromUCI: prev.pv, maxPlies: 6)))
            sans += after.sanLine(fromUCI: e.pv, maxPlies: 6) + before.sanLine(fromUCI: prev.pv, maxPlies: 6)
        }
        var facts = SummaryFacts(start: start, moves: ids.map { game.nodes[$0].san },
                                 evals: ids.map { review.entries[$0]?.eval },
                                 accuracy: accuracy, phases: review.phaseSummary(game: game),
                                 phaseStarts: starts, moments: moments)
        facts.setHeaders(from: game)
        return Input(facts: facts, allowed: Grounding.allowed(sans))
    }
}
