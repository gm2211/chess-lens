import XCTest
@testable import ChessCore

final class AskGroundingTests: XCTestCase {
    private func pos(_ fen: String) throws -> Position { try Position(fen: fen) }

    // MARK: material

    func testStartPositionIsEqual() throws {
        let m = Position.start.materialSummary
        XCTAssertEqual(m.whitePoints, 39); XCTAssertEqual(m.blackPoints, 39)
        XCTAssertEqual(m.difference, 0)
        XCTAssertEqual(m.sentence, "Material is equal.")
        XCTAssertTrue(m.promptText.contains("White: 1 queen, 2 rooks, 2 bishops, 2 knights, 8 pawns = 39 points"))
    }

    func testRookForPawn() throws {
        // White: rooks x2 + pawn (11). Black: two pawns (2).
        let m = try pos("4k3/pp6/8/8/8/8/P7/R3K2R w - - 0 1").materialSummary
        XCTAssertEqual(m.whitePoints, 11); XCTAssertEqual(m.blackPoints, 2)
        XCTAssertEqual(m.sentence, "White is up two rooks for a pawn (+9 points).")
    }

    func testUpAPieceForPawns() throws {
        // White: knight + 1 pawn (4). Black: 3 pawns (3).
        let m = try pos("4k3/ppp5/8/8/8/8/P7/N3K3 w - - 0 1").materialSummary
        XCTAssertEqual(m.difference, 1)
        XCTAssertEqual(m.sentence, "White is up a knight for two pawns (+1 point).")
    }

    func testBlackAheadAndLevelButDifferent() throws {
        let b = try pos("4k2q/8/8/8/8/8/8/4K3 w - - 0 1").materialSummary
        XCTAssertEqual(b.sentence, "Black is up a queen (+9 points).")
        let l = try pos("4kb2/8/8/8/8/8/8/3NK3 w - - 0 1").materialSummary
        XCTAssertEqual(l.difference, 0)
        XCTAssertTrue(l.sentence.contains("White has a knight where Black has a bishop"))
    }

    func testOperaGameAfterCastling() throws {
        // Morphy-Duke of Brunswick after 12.O-O-O: White gave up a piece for two pawns, so Black is up one point
        // on material (while the engine still says White is winning): the model must not recount this itself.
        let pgn = "1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O *"
        let g = PGN.parse(pgn)[0].game
        let m = try XCTUnwrap(g.nodes.last).position.materialSummary
        XCTAssertEqual(m.difference, -1)
        XCTAssertEqual(m.sentence, "Black is up two knights for a bishop and two pawns (+1 point).")
    }

    // MARK: verdict

    func testVerdictWording() {
        XCTAssertEqual(EngineVerdict.describe(.cp(575)), "White is winning")
        XCTAssertEqual(EngineVerdict.describe(.cp(300)), "White is winning")
        XCTAssertEqual(EngineVerdict.describe(.cp(299)), "White is clearly better")
        XCTAssertEqual(EngineVerdict.describe(.cp(150)), "White is clearly better")
        XCTAssertEqual(EngineVerdict.describe(.cp(149)), "White is a bit better")
        XCTAssertEqual(EngineVerdict.describe(.cp(50)), "White is a bit better")
        XCTAssertEqual(EngineVerdict.describe(.cp(49)), "The position is about equal")
        XCTAssertEqual(EngineVerdict.describe(.cp(-49)), "The position is about equal")
        XCTAssertEqual(EngineVerdict.describe(.cp(-80)), "Black is a bit better")
        XCTAssertEqual(EngineVerdict.describe(.cp(-200)), "Black is clearly better")
        XCTAssertEqual(EngineVerdict.describe(.cp(-900)), "Black is winning")
        XCTAssertEqual(EngineVerdict.describe(.mate(3)), "White mates in 3")
        XCTAssertEqual(EngineVerdict.describe(.mate(-2)), "Black mates in 2")
        XCTAssertEqual(EngineVerdict.describe(.checkmate(winner: .black)), "Black has won by checkmate")
        XCTAssertEqual(EngineVerdict.line(.cp(575)), "+5.75 from White's point of view: White is winning.")
    }

    // MARK: contradiction heuristic

    func testContradictionsFromTheBugReport() {
        let wrong = "No, the game isn't lost. Black has given up two pawns for a piece, so it is roughly level or slightly better for Black."
        XCTAssertEqual(AnswerCheck.contradiction(answer: wrong, eval: .cp(575)), "White is winning")
        XCTAssertNotNil(AnswerCheck.contradiction(answer: "The position is balanced.", eval: .cp(400)))
        XCTAssertNotNil(AnswerCheck.contradiction(answer: "Black is slightly better here.", eval: .cp(120)))
        XCTAssertNotNil(AnswerCheck.contradiction(answer: "The game is about equal.", eval: .cp(200)))
        XCTAssertNotNil(AnswerCheck.contradiction(answer: "Black is doing fine, it's not lost yet.", eval: .mate(4)))
        XCTAssertNotNil(AnswerCheck.contradiction(answer: "White is winning easily.", eval: .cp(10)))
    }

    func testConsistentAnswersPass() {
        XCTAssertNil(AnswerCheck.contradiction(
            answer: "Yes, Black is in deep trouble: White is winning because the king is exposed. Black is not equal in development.",
            eval: .cp(575)))
        XCTAssertNil(AnswerCheck.contradiction(answer: "White is a bit better, but the game is far from decided.", eval: .cp(90)))
        XCTAssertNil(AnswerCheck.contradiction(answer: "The position is about equal; both sides have chances.", eval: .cp(10)))
        XCTAssertNil(AnswerCheck.contradiction(answer: "The trade is equal in value, yet White is clearly better.", eval: .cp(200)))
        XCTAssertNil(AnswerCheck.contradiction(answer: "Black is lost.", eval: .cp(-900)))
        XCTAssertNil(AnswerCheck.contradiction(answer: "Black is better and should win.", eval: .cp(-500)))
    }

    func testCorrectiveNote() {
        XCTAssertEqual(AnswerCheck.correctiveNote(verdict: "White is winning"),
                       "Your previous answer contradicted the engine: White is winning. Answer again consistent with the data.")
    }

    // MARK: prompt data block

    func testPromptCarriesEngineAndMaterialData() throws {
        let p = try pos("r1bk3r/ppp2ppp/8/8/8/8/PPP2PPP/2KR3R b - - 0 12")
        let line = EngineToolLine(eval: .cp(575), pv: ["d8e7", "h1e1"])
        var s = AskPrompt.Subject(position: p, history: [])
        s.engine = AskPrompt.EngineReport(lines: [line], depth: 18)
        let text = AskPrompt.user(s, turns: [], question: "Is it lost?")
        XCTAssertTrue(text.contains("Material (counted by the app, ground truth): White:"))
        XCTAssertTrue(text.contains("Engine evaluation (Stockfish, ground truth): +5.75 from White's point of view: White is winning."))
        XCTAssertTrue(text.contains("Stockfish, depth 18. Black to move."))
        XCTAssertTrue(text.contains("1) "))
        XCTAssertTrue(text.contains("Is it lost?"))
        // Compact keeps the verdict and the material too.
        let c = AskPrompt.user(s, turns: [], question: "Is it lost?", compact: true)
        XCTAssertTrue(c.contains("White is winning"))
        XCTAssertTrue(c.contains("Material (counted by the app"))
    }

    func testReportWithoutEngineStillHasMaterial() throws {
        let s = AskPrompt.Subject(position: .start, history: [])
        let text = AskPrompt.user(s, turns: [], question: "Plan?")
        XCTAssertTrue(text.contains("Material is equal."))
        XCTAssertFalse(text.contains("Engine evaluation (Stockfish"))
    }

    func testSystemRules() {
        let t = AskPrompt.system(tool: true)
        XCTAssertTrue(t.contains("ground truth"))
        XCTAssertTrue(t.contains("never recount"))
        XCTAssertTrue(t.contains("check it with the engine tool"))
        XCTAssertFalse(AskPrompt.system(tool: false).contains("check it with the engine tool"))
        XCTAssertTrue(AskPrompt.system(tool: false).contains("ground truth"))
    }
}
