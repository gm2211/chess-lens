import Foundation
import Observation
import ChessCore

/// One line of the "Ask AI" chat.
struct AskMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        /// `unverified`: moves still cited without support after the retry (shown with a marker).
        /// `conflict`: the engine's verdict when the answer still contradicts it after the retry.
        case assistant(unverified: [String], conflict: String? = nil)
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

    /// Live analysis at least this deep is reused instead of running a fresh search.
    static let minLiveDepth = 14

    private(set) var messages: [AskMessage] = []
    private(set) var status: Status = .idle
    /// The answer as it streams in, while `status` is `.thinking`.
    private(set) var partial: String?
    /// "Switched to Grok \u{2014} asking again\u{2026}" while a question restarts after a model switch.
    private(set) var switchNote: String?
    var isOpen = false
    var draft = ""

    @ObservationIgnored private var turns: [AskPrompt.Turn] = []
    @ObservationIgnored private var known = Set<String>()
    @ObservationIgnored private var askedAt: Int?
    var askedNode: Int? { askedAt }
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
        status = .idle; partial = nil; switchNote = nil
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

    /// The provider or model changed while a question was in flight or had failed: ask it again with the new one.
    func providerChanged(game: Game, review: ReviewModel, live: AskPrompt.EngineReport? = nil) {
        guard let q = lastQuestion, let node = askedAt, game.nodes.indices.contains(node) else { return }
        switch status {
        case .thinking, .failed, .needsSignIn: break
        case .idle: return
        }
        task?.cancel(); task = nil
        partial = nil
        if case .user? = messages.last?.kind { messages.removeLast() }
        status = .idle
        ask(q, game: game, review: review, node: node, live: live)
        switchNote = "Switched to \(hub.selected.displayName) \u{2014} asking again\u{2026}"
    }

    /// Asks again after a failure.
    func retry(game: Game, review: ReviewModel, node: Int, live: AskPrompt.EngineReport? = nil) {
        guard let q = lastQuestion, !isThinking else { return }
        if case .user? = messages.last?.kind { messages.removeLast() }
        status = .idle
        ask(q, game: game, review: review, node: node, live: live)
    }

    func ask(_ question: String, game: Game, review: ReviewModel, node id: Int, live: AskPrompt.EngineReport? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking, game.nodes.indices.contains(id) else { return }
        let ctx = Self.context(game: game, review: review, id: id)
        if let last = askedAt, last != id, !messages.isEmpty {
            messages.append(AskMessage(kind: .note, text: "\u{2014} now at \(Self.moveText(game: game, id: id)) \u{2014}"))
        }
        messages.append(AskMessage(kind: .user, text: q))
        draft = ""
        status = .thinking; partial = nil; switchNote = nil
        askedAt = id; lastQuestion = q
        let turnsSoFar = turns
        let noted = AskPrompt.illegalMoveNotes(question: q, subject: ctx.subject).flatMap(\.sans)
        let extra = known.union(Grounding.allowed(AskPrompt.citedMoves(in: turns.map(\.question) + [q]) + noted))
        task = Task { await run(q, ctx, live: live, turns: turnsSoFar, extra: extra) }
    }

    private func run(_ q: String, _ ctx: Context, live: AskPrompt.EngineReport?, turns: [AskPrompt.Turn], extra: Set<String>) async {
        do {
            if !hub.isReady { await hub.refresh(hub.selected) }
            guard hub.isReady else { fail(.needsSignIn); return }
            // Apple's on-device model has a small context window: start compact there.
            let compactFirst = hub.selected == .apple
            // Ground the question: Stockfish on the asked position (and the one before) goes into the prompt as data.
            let ctx = await seeded(ctx, live: live, includeBefore: !compactFirst)
            try Task.checkCancellation()
            let allowed = ctx.allowed.union(extra)
            var compact = compactFirst, tool = true
            var answer: GroundedAnswer
            do {
                answer = try await attempt(q, ctx, turns, allowed, compact: compact, tool: tool)
            } catch where !compactFirst && AIToolLoop.isContextLimit(error) {
                compact = true; tool = false
                answer = try await attempt(q, ctx, turns, allowed, compact: compact, tool: tool)
            }
            if Task.isCancelled { return }
            // An answer that contradicts the engine's verdict gets one more try with a corrective note.
            var conflict: String?
            if let e = ctx.subject.verdictEval, let v = AnswerCheck.contradiction(answer: answer.text, eval: e) {
                let again = try await attempt(q, ctx, turns, allowed.union(answer.allowed), compact: compact, tool: tool,
                                              note: AnswerCheck.correctiveNote(verdict: v))
                if Task.isCancelled { return }
                answer = again
                conflict = AnswerCheck.contradiction(answer: again.text, eval: e)
            }
            guard !answer.text.isEmpty else { fail(.failed("The model returned no text.")); return }
            messages.append(AskMessage(kind: .assistant(unverified: answer.unsupported, conflict: conflict), text: answer.text))
            self.turns.append(AskPrompt.Turn(context: ctx.label, question: q, answer: answer.text))
            known.formUnion(answer.allowed)
            status = .idle; partial = nil; task = nil; switchNote = nil
        } catch {
            // A cancelled run leaves things to whoever cancelled it (`cancel()` or a restart).
            if Task.isCancelled || error is CancellationError || (error as? LLMError) == .canceled { return }
            if let e = error as? LLMError, e.needsSignIn {
                fail(.needsSignIn)
                await hub.refresh(hub.selected)
            } else {
                fail(.failed(hub.failureText(for: error)))
            }
        }
    }

    private func fail(_ s: Status) {
        status = s; partial = nil; task = nil; switchNote = nil
    }

    private func attempt(_ q: String, _ ctx: Context, _ turns: [AskPrompt.Turn], _ allowed: Set<String>,
                         compact: Bool, tool: Bool, note: String? = nil) async throws -> GroundedAnswer {
        try await AIToolLoop.run(hub: hub, system: AskPrompt.system(tool: tool, compact: compact),
                                 prompt: AskPrompt.user(ctx.subject, turns: turns, question: q, compact: compact),
                                 maxTokens: 500, allowed: allowed, tool: tool,
                                 seed: tool ? Self.namedMoveChecks(q, ctx.subject) : [], note: note, timeout: .ask,
                                 onPartial: { [weak self] text in if self?.status == .thinking { self?.partial = text } })
    }

    /// Adds Stockfish's view of the asked position (and of the one before the last move) to the context: reuses the
    /// live analysis when given, otherwise runs the tool engine. Fills the review's gaps (`evalNow`, `line`) and
    /// allows the moves the results show. An engine failure leaves the context as it was.
    private func seeded(_ ctx: Context, live: AskPrompt.EngineReport?, includeBefore: Bool) async -> Context {
        var c = ctx
        var sans: [String] = []
        func report(_ p: Position, reuse: AskPrompt.EngineReport?) async -> AskPrompt.EngineReport? {
            if let reuse { return reuse }
            guard !p.legalMoves().isEmpty, let r = try? await ToolEngine.shared.analyse(p), !r.lines.isEmpty else { return nil }
            return AskPrompt.EngineReport(lines: r.lines, depth: r.depth)
        }
        if let r = await report(c.subject.position, reuse: live) {
            c.subject.engine = r
            sans += r.text(for: c.subject.position).sans
            if c.subject.evalNow == nil { c.subject.evalNow = r.lines.first?.eval }
            if c.subject.line.isEmpty { c.subject.line = r.lines.first?.pv ?? [] }
        }
        if includeBefore, !Task.isCancelled, let before = c.subject.before, let r = await report(before, reuse: nil) {
            c.subject.engineBefore = r
            sans += r.text(for: before).sans
            if c.subject.evalBefore == nil { c.subject.evalBefore = r.lines.first?.eval }
            if c.subject.best.isEmpty { c.subject.best = r.lines.first?.pv ?? [] }
        }
        c.allowed.formUnion(Grounding.allowed(sans))
        return c
    }

    /// Moves the user names ("why not Qh5?") are run through the engine before the model answers, from the position
    /// before the last move when legal there (the usual "instead of" question), otherwise from the current position.
    static func namedMoveChecks(_ q: String, _ s: AskPrompt.Subject) -> [EngineToolRequest] {
        var out: [EngineToolRequest] = []
        // Bare pawn moves ("why not e5?") aren't citations elsewhere (they read like squares); here a legal one counts.
        let pushes = q.matches(of: /\b[a-h][1-8]\b/).map { String($0.output) }
        // Spoken moves ("queen to d1", "knight f3") count like SAN ones when legal in either position.
        let spoken = AskPrompt.namedMoves(in: q).flatMap { n in
            [s.before, s.position].compactMap { $0 }.first { !AskPrompt.legalSANs(for: n, in: $0).isEmpty }
                .map { AskPrompt.legalSANs(for: n, in: $0) } ?? []
        }
        for san in AskPrompt.citedMoves(in: [q]) + spoken + pushes {
            let from = [s.before, s.position].compactMap { $0 }.first { (try? $0.parseSAN(san)) != nil }
            guard let from else { continue }
            let r = EngineToolRequest(fen: from.fen, moves: [san])
            if !out.contains(r) { out.append(r) }
            if out.count == 3 { break }
        }
        return out
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
