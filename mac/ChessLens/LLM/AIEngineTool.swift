import Foundation
import ChessCore

/// A Stockfish of its own for the AI's engine tool, so tool calls never stop live analysis or a review.
/// Calls are queued: the engine runs one search at a time, and several explanations may ask at once.
actor ToolEngine {
    static let shared = ToolEngine()
    static let depth = 18, milliseconds = 1500, lines = 3

    private var engine: UCIEngine?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }   // `busy` stays true: the releaser hands over
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Top lines (White's view) at depth 18 or 1.5 s, whichever comes first.
    func analyse(_ position: Position) async throws -> (lines: [EngineToolLine], depth: Int) {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if engine == nil {
            guard let url = UCIEngine.defaultExecutableURL else { throw EngineError.executableMissing }
            engine = UCIEngine(executableURL: url, threads: 2, hash: 64)
        }
        let stream = try await engine!.search(fen: position.fen, limit: .depthTime(depth: Self.depth, ms: Self.milliseconds),
                                              multiPV: Self.lines)
        var latest: [Int: UCIInfo] = [:]
        var depth = 0
        for await event in stream {
            if Task.isCancelled { break }
            if case .info(let i) = event, i.hasScore, !i.isBound, !i.pv.isEmpty {
                latest[i.multipv] = i
                if i.multipv == 1 { depth = i.depth }
            }
        }
        let white = position.turn == .white
        let lines = latest.keys.sorted().compactMap { k -> EngineToolLine? in
            guard let i = latest[k], let e = i.eval(whiteToMove: white) else { return nil }
            return EngineToolLine(eval: e, pv: i.pv)
        }
        return (lines, depth)
    }
}

/// An answer that went through the engine-tool loop and the move check.
struct GroundedAnswer {
    var text: String
    /// Normalized SAN the answer may cite: the supplied data plus everything the engine showed.
    var allowed: Set<String>
    /// Moves still cited without support after the one retry (empty when clean).
    var unsupported: [String]
    var toolCalls: Int
}

/// Runs a completion with the engine tool (see `EngineTool`): while the model replies with an `<engine/>` tag the
/// app answers it and re-sends the transcript; the final answer's moves are checked against the data, and if any
/// are unsupported the model is asked once more with a note naming them.
@MainActor
enum AIToolLoop {
    static func run(hub: AIHub, system: String, prompt: String, maxTokens: Int,
                    allowed base: Set<String>, tool: Bool) async throws -> GroundedAnswer {
        var allowed = base
        var turns: [EngineTool.Turn] = []
        var calls = 0
        // Apple's on-device model has a small context; each round re-sends the transcript.
        let budget = tool ? (hub.selected == .apple ? 2 : EngineTool.maxCalls) : 0
        var note: String?
        var retried = false
        for _ in 0..<(budget + 4) {
            try Task.checkCancellation()
            let p = EngineTool.transcript(prompt: prompt, turns: turns, callsLeft: max(0, budget - calls), note: note)
            let text = try await collect(hub: hub, system: system, prompt: p, maxTokens: maxTokens, stopAtTag: budget > 0)
            let requests = EngineTool.requests(in: text)
            let final = stripTags(text)
            if !requests.isEmpty, calls < budget {
                for r in requests.prefix(budget - calls) {
                    calls += 1
                    turns.append(EngineTool.Turn(request: r.tag, reply: await answer(r, allowed: &allowed)))
                }
                continue
            }
            // Out of calls but still only asking: the transcript now says to answer without the tag.
            if final.isEmpty, !requests.isEmpty { calls = budget; continue }
            let bad = Grounding.unsupported(in: final, allowed: allowed)
            if !bad.isEmpty, !retried {
                retried = true
                note = "Your previous answer cited moves that are not in the data or the engine results: "
                    + bad.joined(separator: ", ")
                    + ". Only mention moves from the data" + (calls < budget ? ", or check them with the engine tool first" : "")
                    + ". Answer again."
                continue
            }
            return GroundedAnswer(text: final, allowed: allowed, unsupported: bad, toolCalls: calls)
        }
        throw LLMError.server(code: "tool-loop", message: "The model kept asking for the engine without answering.")
    }

    /// The engine's reply to one request (or an error the model can act on). Adds the moves shown to `allowed`.
    private static func answer(_ r: EngineToolRequest, allowed: inout Set<String>) async -> String {
        switch EngineTool.resolve(r) {
        case .failure(let f):
            return f.message
        case .success(let resolved):
            let position = resolved.position, sans = resolved.sans
            let start = (try? Position(fen: r.fen)) ?? position
            var lines: [EngineToolLine] = [], depth = 0
            if !position.legalMoves().isEmpty {
                do { (lines, depth) = try await ToolEngine.shared.analyse(position) } catch {
                    return "Engine error: the engine is unavailable (\(error.localizedDescription)). Answer from the data."
                }
            }
            let out = EngineTool.result(for: r, start: start, sans: sans, position: position, lines: lines, depth: depth)
            allowed.formUnion(Grounding.allowed(out.sans))
            return out.text
        }
    }

    /// Collects the streamed answer; with `stopAtTag`, stops reading as soon as a complete engine tag has arrived.
    private static func collect(hub: AIHub, system: String, prompt: String, maxTokens: Int, stopAtTag: Bool) async throws -> String {
        var text = ""
        for try await chunk in hub.complete(system: system, prompt: prompt, maxTokens: maxTokens) {
            text += chunk
            if stopAtTag, EngineTool.hasCompleteRequest(text) { break }
        }
        try Task.checkCancellation()
        return text
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<engine\b[^<>]*/?>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a provider error looks like "the prompt is too long", so the caller can retry with less.
    static func isContextLimit(_ error: Error) -> Bool {
        let m = error.localizedDescription.lowercased()
        return ["context", "too long", "too many tokens", "token limit", "maximum length", "exceeded"].contains { m.contains($0) }
    }
}
