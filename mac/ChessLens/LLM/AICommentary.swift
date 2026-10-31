import Foundation
import Observation
import ChessCore

/// AI explanations of reviewed moves, cached per node id. Owned by `ReviewModel`, so it is cleared
/// (and in-flight requests are cancelled) whenever the review restarts or a different game loads.
@Observable @MainActor
final class AICommentary {
    enum State: Equatable {
        case loading
        case text(String)
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

    func explain(_ id: Int, game: Game, review: ReviewModel) {
        guard tasks[id] == nil, let prompt = Self.prompt(game: game, review: review, id: id) else { return }
        states[id] = .loading
        tasks[id] = Task {
            await run(id, prompt: prompt)
            tasks[id] = nil
        }
    }

    /// Explains every id without a cached explanation, one at a time.
    func explainAll(_ ids: [Int], game: Game, review: ReviewModel) {
        guard batchTask == nil else { return }
        let todo = ids.filter { if case .text? = states[$0] { false } else { true } }
        guard !todo.isEmpty else { return }
        batch = (0, todo.count)
        batchTask = Task {
            for (i, id) in todo.enumerated() {
                if Task.isCancelled { break }
                guard let prompt = Self.prompt(game: game, review: review, id: id) else { continue }
                states[id] = .loading
                await run(id, prompt: prompt)
                batch = (i + 1, todo.count)
                if states[id] == .needsSignIn { break }
            }
            batch = nil; batchTask = nil
        }
    }

    private func run(_ id: Int, prompt: String) async {
        do {
            // Never signs in: with no provider set up the line just says so (Settings > AI, or the header chip).
            if !hub.isReady { await hub.refresh(hub.selected) }
            guard hub.isReady else { states[id] = .needsSignIn; return }
            var text = ""
            for try await chunk in hub.complete(system: CoachPrompt.system, prompt: prompt, maxTokens: 400) {
                text += chunk
            }
            if Task.isCancelled { if states[id] == .loading { states[id] = nil }; return }
            let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
            states[id] = out.isEmpty ? .failed("The model returned no text.") : .text(out)
        } catch is CancellationError {
            if states[id] == .loading { states[id] = nil }
        } catch LLMError.canceled {
            if states[id] == .loading { states[id] = nil }
        } catch let e as LLMError where e.needsSignIn {
            states[id] = .needsSignIn
            await hub.refresh(hub.selected)
        } catch {
            if Task.isCancelled { if states[id] == .loading { states[id] = nil }; return }
            states[id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Prompt

    static func prompt(game: Game, review: ReviewModel, id: Int) -> String? {
        guard game.nodes.indices.contains(id), let pid = game.nodes[id].parent, let move = game.nodes[id].move,
              let entry = review.entries[id], let prev = review.entries[pid] else { return nil }
        var history: [String] = []
        var cur = game.nodes[pid]
        while let p = cur.parent { history.append(cur.san); cur = game.nodes[p] }
        let before = game.nodes[pid].position
        let kind: String? = switch entry.cls {
        case .blunder?: "blunder"
        case .mistake?: "mistake"
        case .inaccuracy?: "inaccuracy"
        case nil: nil
        }
        return CoachPrompt.user(
            before: before, move: move, classification: kind,
            evalBefore: prev.eval, evalAfter: entry.eval,
            tags: before.lineTags(played: move, refutation: entry.pv, best: prev.pv, evalAfter: entry.eval),
            refutation: entry.pv, best: prev.pv, history: history.reversed())
    }
}
