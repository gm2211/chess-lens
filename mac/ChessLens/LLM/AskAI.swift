import Foundation
import Observation
import ChessCore

/// One line of the "Ask AI" chat.
struct AskMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        /// `unverified`: moves still cited without support after the retry (shown with a marker).
        case assistant(unverified: [String])
        /// A divider such as "now at 12. O-O-O" when the board moved between questions.
        case note
    }
    let id = UUID()
    var kind: Kind
    var text: String
}

/// Free-form questions about the position on the board, answered by the AI with Stockfish to check its ideas.
/// Owned by `AppModel`: cleared (and a request in flight is cancelled) when another game loads, and never used
/// while a play session hides the evaluation.
@Observable @MainActor
final class AskAI {
    enum Status: Equatable {
        case idle
        case thinking
        case needsSignIn
        case failed(String)
    }

    private(set) var messages: [AskMessage] = []
    private(set) var status: Status = .idle
    /// The answer as it streams in, while `status` is `.thinking`.
    private(set) var partial: String?
    var isOpen = false
    var draft = ""

    @ObservationIgnored private var turns: [AskPrompt.Turn] = []
    @ObservationIgnored private var known = Set<String>()
    @ObservationIgnored private var askedAt: Int?
    @ObservationIgnored private var lastQuestion: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let hub: AIHub

    init(hub: AIHub = .shared) { self.hub = hub }

    var isThinking: Bool { status == .thinking }

    /// Back to nothing: another game loaded, or the evaluation went into hiding.
    func reset() {
        clear()
        isOpen = false
        draft = ""
    }

    /// Empties the conversation (and stops a request in flight).
    func clear() {
        task?.cancel(); task = nil
        messages = []; turns = []; known = []
        askedAt = nil; lastQuestion = nil
        status = .idle; partial = nil
    }

    func close() {
        cancel()
        isOpen = false
    }

    /// Stops the request in flight; its question goes back into the text field.
    func cancel() {
        task?.cancel(); task = nil
        guard status == .thinking else { return }
        status = .idle; partial = nil
        if case .user? = messages.last?.kind {
            if draft.isEmpty { draft = messages.last?.text ?? "" }
            messages.removeLast()
        }
    }

    /// Asks again after a failure.
    func retry(game: Game, review: ReviewModel, node: Int) {
        guard let q = lastQuestion, !isThinking else { return }
        if case .user? = messages.last?.kind { messages.removeLast() }
        status = .idle
        ask(q, game: game, review: review, node: node)
    }

    func ask(_ question: String, game: Game, review: ReviewModel, node id: Int) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking, game.nodes.indices.contains(id) else { return }
        let ctx = Self.context(game: game, review: review, id: id)
        if let last = askedAt, last != id, !messages.isEmpty {
            messages.append(AskMessage(kind: .note, text: "\u{2014} now at \(Self.moveText(game: game, id: id)) \u{2014}"))
        }
        messages.append(AskMessage(kind: .user, text: q))
        draft = ""
        status = .thinking; partial = nil
        askedAt = id; lastQuestion = q
        let turnsSoFar = turns
        let extra = known.union(Grounding.allowed(AskPrompt.citedMoves(in: turns.map(\.question) + [q])))
        task = Task { await run(q, ctx, turns: turnsSoFar, extra: extra) }
    }

    private func run(_ q: String, _ ctx: Context, turns: [AskPrompt.Turn], extra: Set<String>) async {
        do {
            if !hub.isReady { await hub.refresh(hub.selected) }
            guard hub.isReady else { fail(.needsSignIn); return }
            let allowed = ctx.allowed.union(extra)
            // Apple's on-device model has a small context window: start compact there.
            let compactFirst = hub.selected == .apple
            let answer: GroundedAnswer
            do {
                answer = try await attempt(q, ctx, turns, allowed, compact: compactFirst, tool: true)
            } catch where !compactFirst && AIToolLoop.isContextLimit(error) {
                answer = try await attempt(q, ctx, turns, allowed, compact: true, tool: false)
            }
            if Task.isCancelled { return }
            guard !answer.text.isEmpty else { fail(.failed("The model returned no text.")); return }
            messages.append(AskMessage(kind: .assistant(unverified: answer.unsupported), text: answer.text))
            self.turns.append(AskPrompt.Turn(context: ctx.label, question: q, answer: answer.text))
            known.formUnion(answer.allowed)
            status = .idle; partial = nil; task = nil
        } catch is CancellationError {
            // `cancel()` already put things back.
        } catch LLMError.canceled {
        } catch let e as LLMError where e.needsSignIn {
            fail(.needsSignIn)
            await hub.refresh(hub.selected)
        } catch {
            if Task.isCancelled { return }
            fail(.failed(error.localizedDescription))
        }
    }

    private func fail(_ s: Status) {
        status = s; partial = nil; task = nil
    }

    private func attempt(_ q: String, _ ctx: Context, _ turns: [AskPrompt.Turn], _ allowed: Set<String>,
                         compact: Bool, tool: Bool) async throws -> GroundedAnswer {
        try await AIToolLoop.run(hub: hub, system: AskPrompt.system(tool: tool, compact: compact),
                                 prompt: AskPrompt.user(ctx.subject, turns: turns, question: q, compact: compact),
                                 maxTokens: 500, allowed: allowed, tool: tool,
                                 onPartial: { [weak self] text in if self?.status == .thinking { self?.partial = text } })
    }

    // MARK: Context

    struct Context: Sendable {
        var subject: AskPrompt.Subject
        /// "After 10…cxb5 · White to move".
        var label: String
        /// Normalized SAN the answer may cite: the game so far and the review's engine lines.
        var allowed: Set<String>
    }

    /// The position at node `id` with everything the app knows about it: the move that led there, and the review's
    /// scores and lines if a review ran.
    static func context(game: Game, review: ReviewModel, id: Int) -> Context {
        let node = game.nodes[id]
        var history: [String] = []
        var cur = node
        while let p = cur.parent { history.append(cur.san); cur = game.nodes[p] }
        history.reverse()
        var s = AskPrompt.Subject(position: node.position, history: history)
        var sans = history
        let entry = review.entries[id]
        s.evalNow = entry?.eval
        s.line = entry?.pv ?? []
        sans += node.position.sanLine(fromUCI: s.line, maxPlies: 8)
        if let pid = node.parent, let move = node.move {
            let before = game.nodes[pid].position
            let prev = review.entries[pid]
            s.before = before; s.move = move
            s.classification = entry?.cls?.name
            s.evalBefore = prev?.eval
            s.best = prev?.pv ?? []
            if let entry, let prev {
                s.tags = before.lineTags(played: move, refutation: entry.pv, best: prev.pv, evalAfter: entry.eval)
            }
            sans += before.sanLine(fromUCI: s.best, maxPlies: 8)
        }
        if review.hasResults { s.phase = review.phases(game: game)[id] }
        return Context(subject: s, label: AskPrompt.contextLabel(position: s.position, before: s.before, move: s.move),
                       allowed: Grounding.allowed(sans))
    }

    /// "12. O-O-O" / "12…Rd8" for the move that led to node `id`; "the start" for the root.
    static func moveText(game: Game, id: Int) -> String {
        let n = game.nodes[id]
        guard let p = n.parent else { return "the start" }
        let before = game.nodes[p].position
        return before.turn == .white ? "\(before.fullmove). \(n.san)" : "\(before.fullmove)\u{2026}\(n.san)"
    }

    /// What the empty chat suggests for node `id`.
    static func starters(game: Game, review: ReviewModel, id: Int) -> [String] {
        let entry = review.entries[id]
        var alt: String?
        if let pid = game.nodes[id].parent, let move = game.nodes[id].move,
           let uci = review.entries[pid]?.best, uci != move.uci {
            let before = game.nodes[pid].position
            alt = before.move(fromUCI: uci).map { before.san($0) }
        }
        return AskPrompt.starters(classification: entry?.cls?.name, isError: entry?.cls?.isError ?? false, bestAlternative: alt)
    }
}
