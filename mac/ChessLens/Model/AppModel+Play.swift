import Foundation
import ChessCore

/// Entry points for "Continue against engine". The session itself lives in `PlaySession`.
extension AppModel {
    /// Whether the pieces are locked (a session is running and it is not the player's turn).
    var boardLocked: Bool { playSession.map { !$0.acceptsInput } ?? false }
    var hidesEvaluation: Bool { playSession?.hidesEvaluation ?? false }

    /// Opens the setup sheet, or stops the current session.
    func togglePlay() {
        if playSession != nil { endPlay() } else { requestPlay() }
    }

    func requestPlay() {
        guard engine.isAvailable else { showToast("The engine is not available in this build."); return }
        guard !review.running else { showToast("Wait for the review to finish first."); return }
        guard game.gameEnd(at: currentID) == nil else { showToast("This game is already over."); return }
        showPlaySetup = true
    }

    /// Jumps to a move, then opens the setup sheet.
    func requestPlay(from id: Int) {
        goto(id)
        requestPlay()
    }

    func beginPlay(_ setup: PlaySetup) {
        endPlay()
        setup.save()
        flipped = setup.userSide == .black
        let session = PlaySession(app: self, setup: setup, start: currentID)
        playSession = session
        if session.hidesEvaluation { ask.reset() }      // the answers would leak what the engine thinks
        refreshEngine()
        session.begin()
    }

    func endPlay() {
        guard let session = playSession else { return }
        playSession = nil
        session.end()
        refreshEngine()
    }

    /// Ends the session and runs the usual review on the game that was played.
    func reviewPlayedGame() {
        endPlay()
        showInspector = true
        startReview()
    }
}
