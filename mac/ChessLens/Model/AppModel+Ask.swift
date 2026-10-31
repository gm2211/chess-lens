import Foundation

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

    func sendAsk(_ question: String) {
        guard canAskAI else { return }
        ask.ask(question, game: game, review: review, node: currentID)
    }
}
