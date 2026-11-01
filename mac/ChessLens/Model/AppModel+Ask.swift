import Foundation
import ChessCore

/// Entry points for "Ask AI". The conversation itself lives in `AskAI`.
extension AppModel {
    /// Why asking is unavailable right now, or nil when it is available.
    var askUnavailableReason: String? {
        if hidesEvaluation { return "Ask AI is off while the engine's evaluation is hidden" }
        if !AIHub.shared.isReady { return "Set up an AI provider first (the chip in the side panel header)" }
        return nil
    }

    var canAskAI: Bool { askUnavailableReason == nil }

    func toggleAsk() {
        if ask.isOpen { ask.close() } else { openAsk() }
    }

    /// Opens the chat on the current position.
    func openAsk() {
        guard canAskAI else { return }
        showInspector = true
        ask.isOpen = true
    }

    /// Jumps to a move, then opens the chat.
    func askAbout(_ id: Int) {
        goto(id)
        openAsk()
    }

    /// The user picked another AI provider or model: lesson, notes and a pending question that were hung or failed
    /// start over with it (see `ReviewModel.providerChanged`, `AskAI.providerChanged`).
    func aiSelectionChanged() {
        review.providerChanged(game: game)
        ask.providerChanged(game: game, review: review, live: ask.askedNode == currentID ? liveEngineReport : nil)
    }

    func sendAsk(_ question: String) {
        guard canAskAI else { return }
        ask.ask(question, game: game, review: review, node: currentID, live: liveEngineReport)
    }

    /// The live analysis of the current position when it is complete enough to ground an answer (depth 14 or more,
    /// for this exact position, not shared with a running review); nil otherwise (Ask AI then runs its own search).
    private var liveEngineReport: AskPrompt.EngineReport? {
        guard engineEnabled, !review.running, engine.linesFEN == position.fen,
              let top = engine.lines.first, top.depth >= AskAI.minLiveDepth else { return nil }
        let lines = engine.lines.filter { $0.depth >= AskAI.minLiveDepth }.map { EngineToolLine(eval: $0.eval, pv: $0.pv) }
        return AskPrompt.EngineReport(lines: lines, depth: top.depth)
    }
}
