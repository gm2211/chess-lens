import Foundation
import Observation
import ChessCore

/// AI lessons on reviewed moves, cached per node id. Owned by `ReviewModel`, so it is cleared
/// (and in-flight requests are cancelled) whenever the review restarts or a different game loads.
@Observable @MainActor
final class AICommentary {
    enum State: Equatable {
        case loading
        /// `unverified`: moves the answer still cites without support after the retry (shown with a marker).
        case done(MomentLesson, unverified: [String])
        case needsSignIn
        /// Unused now (AI never signs in on its own); kept so views that switch over `State` still compile.
        case signingIn
        case failed(String)
    }

    private(set) var states: [Int: State] = [:]
    /// Progress of "Explain all": (finished, total), nil when not running.
    private(set) var batch: (done: Int, total: Int)?

    private var tasks: [Int: Task<Void, Never>] = [:]
    private var batchTask: Task<Void, Never>?
    private let hub: AIHub

    init(hub: AIHub = .shared) { self.hub = hub }

    func reset() {
        cancelAll()
        states = [:]
    }

    /// Cancels every in-flight request; cached explanations stay.
    func cancelAll() {
        batchTask?.cancel(); batchTask = nil; batch = nil
        for t in tasks.values { t.cancel() }
        tasks = [:]
        for (id, s) in states where s == .loading || s == .signingIn { states[id] = nil }
    }

    /// The provider or model changed: notes in flight, failed or waiting on a sign-in start over with the new one;
    /// finished notes stay. `automatic` are the notes a batch would have written (see `AIRetry.notesToRun`).
    func providerChanged(game: Game, review: ReviewModel, automatic: [Int]) {
        let jobs = states.map { (id: $0.key, phase: Self.phase($0.value)) }.sorted { $0.id < $1.id }
        let ids = AIRetry.notesToRun(jobs, wanted: automatic, batchWasRunning: batchTask != nil)
        guard !ids.isEmpty else { return }
        cancelAll()
        for id in ids where Self.phase(states[id]) != .done { states[id] = nil }
        explainAll(ids, game: game, review: review)
    }

    static func phase(_ s: State?) -> AIJobPhase {
        switch s {
        case nil: .idle
        case .loading?, .signingIn?: .running
        case .failed?: .failed
        case .needsSignIn?: .needsSignIn
        case .done?: .done
        }
    }

    func explain(_ id: Int, game: Game, review: ReviewModel) {
        guard tasks[id] == nil, states[id] != .loading, let req = Self.request(game: game, review: review, id: id) else { return }
        states[id] = .loading
        tasks[id] = Task {
            await run(id, req)
            if !Task.isCancelled { tasks[id] = nil }
        }
    }

    /// Explains every id without a cached explanation, a few at a time (one at a time on Apple's on-device model).
    func explainAll(_ ids: [Int], game: Game, review: ReviewModel) {
        guard batchTask == nil else { return }
        let todo = ids.filter { id in
            if tasks[id] != nil || states[id] == .loading { return false }
            if case .done? = states[id] { return false }
            return true
        }
        guard !todo.isEmpty else { return }
        batch = (0, todo.count)
        let width = hub.selected == .apple ? 1 : 3
        batchTask = Task {
            var queue = todo[...]
            var finished = 0
            await withTaskGroup(of: Void.self) { group in
                var running = 0, stopped = false
                while true {
                    while running < width, !stopped, let id = queue.popFirst() {
                        guard let req = Self.request(game: game, review: review, id: id) else { finished += 1; continue }
                        states[id] = .loading
                        group.addTask { await self.run(id, req) }
                        running += 1
                    }
                    guard running > 0, await group.next() != nil else { break }
                    running -= 1
                    finished += 1
                    batch = (finished, todo.count)
                    if Task.isCancelled || states.values.contains(.needsSignIn) { stopped = true; group.cancelAll() }
                }
            }
            if !Task.isCancelled {
                // Notes a sign-in stop cancelled mid-way go back to not-asked.
                for id in todo where states[id] == .loading { states[id] = nil }
                batch = nil; batchTask = nil
            }
        }
    }

    private func run(_ id: Int, _ req: Request) async {
        do {
            // Never signs in: with no provider set up the line just says so (Settings > AI, or the header chip).
            if !hub.isReady { await hub.refresh(hub.selected) }
            guard hub.isReady else { states[id] = .needsSignIn; return }
            let answer = try await AIToolLoop.run(hub: hub, system: CoachPrompt.system(tool: true), prompt: req.prompt,
                                                  maxTokens: 350, allowed: req.allowed, tool: true, timeout: .note)
            if Task.isCancelled { return }
            guard let lesson = MomentLesson.parse(answer.text) else { states[id] = .failed("The model returned no text."); return }
            var unverified: [String] = []
            let clean = lesson.mapText { t in
                let c = Grounding.clean(t, allowed: answer.allowed)
                for m in c.unverified where !unverified.contains(m) { unverified.append(m) }
                return c.text
            }
            states[id] = .done(clean, unverified: unverified)
        } catch {
            // A cancelled run leaves the state to whoever cancelled it (a restart may already have set a new one).
            if Task.isCancelled { return }
            if error is CancellationError || (error as? LLMError) == .canceled {
                if states[id] == .loading { states[id] = nil }
            } else if let e = error as? LLMError, e.needsSignIn {
                states[id] = .needsSignIn
                await hub.refresh(hub.selected)
            } else {
                states[id] = .failed(hub.failureText(for: error))
            }
        }
    }

    // MARK: Prompt

    struct Request: Sendable {
        var prompt: String
        /// Normalized SAN the answer may cite: the game so far, the move, and both engine lines.
        var allowed: Set<String>
    }

    static func request(game: Game, review: ReviewModel, id: Int) -> Request? {
        guard game.nodes.indices.contains(id), let pid = game.nodes[id].parent, let move = game.nodes[id].move,
              let entry = review.entries[id], let prev = review.entries[pid] else { return nil }
        var history: [String] = []
        var cur = game.nodes[pid]
        while let p = cur.parent { history.append(cur.san); cur = game.nodes[p] }
        history.reverse()
        let before = game.nodes[pid].position
        let after = game.nodes[id].position
        let kind: String = switch entry.cls {
        case .brilliant?: "brilliant: a sacrifice the engine approves"
        case .great?: "great: a sacrifice the engine approves"
        case let c?: c.name
        case nil: "turning point: the evaluation changed a lot here"
        }
        let prompt = CoachPrompt.user(
            before: before, move: move, classification: kind,
            evalBefore: prev.eval, evalAfter: entry.eval,
            tags: before.lineTags(played: move, refutation: entry.pv, best: prev.pv, evalAfter: entry.eval),
            refutation: entry.pv, best: prev.pv, history: history, phase: review.phases(game: game)[pid])
        let sans = history + [game.nodes[id].san]
            + after.sanLine(fromUCI: entry.pv, maxPlies: 8) + before.sanLine(fromUCI: prev.pv, maxPlies: 8)
        return Request(prompt: prompt, allowed: Grounding.allowed(sans))
    }
}
