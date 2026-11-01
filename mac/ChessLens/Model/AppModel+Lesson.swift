import Foundation
import ChessCore

/// Entry points for the narrated lesson walkthroughs (see `LessonPlayer`).
extension AppModel {
    /// Lessons need the evaluation, so none while playing the engine.
    var canPlayLessons: Bool { playSession == nil }

    /// Starts playing `steps` (story steps with the node of the position each shows); playing the same concept
    /// again while it is open stops it.
    func playLesson(title: String, steps: [LessonPlayer.Step], fullReview: Bool = false) {
        if let p = lessonPlayer, p.title == title { closeLesson(); return }
        guard canPlayLessons, !steps.isEmpty else { return }
        clearLessonFocus()
        walkthrough = nil
        let p = LessonPlayer(title: title, steps: steps, app: self, isFullReview: fullReview)
        lessonPlayer = p
        p.start()
    }

    /// Closes the lesson being played and the guided review.
    func closeLesson() { lessonPlayer = nil; walkthrough = nil }

    /// The step's preview position (a demonstrated line) when one is on the board, else nil.
    var lessonPreview: LessonPlayer.Preview? { walkthrough?.preview ?? lessonPlayer?.preview }

    /// What the board draws: the lesson preview while one is shown, otherwise the current node.
    var boardPosition: Position { lessonPreview?.position ?? position }
    var boardLastMove: Move? { lessonPreview.map(\.lastMove) ?? lastMove }
    func boardPieces() -> [PieceInstance] { lessonPreview?.pieces ?? pieces(for: currentID) }
}
