import XCTest
@testable import ChessCore

final class AskNamedMovesTests: XCTestCase {
    func testParsesSANAndSpokenMoves() {
        XCTAssertEqual(AskPrompt.namedMoves(in: "but Qd1 seems best").map(\.text), ["Qd1"])
        XCTAssertEqual(AskPrompt.namedMoves(in: "the most recommended engine move seems to be queen d1").map(\.text), ["Qd1"])
        XCTAssertEqual(AskPrompt.namedMoves(in: "what about Queen to D 1?").map(\.text), ["Qd1"])
        XCTAssertEqual(AskPrompt.namedMoves(in: "why not knight f3 or night to g five").map(\.text), ["Nf3", "Ng5"])
        XCTAssertEqual(AskPrompt.namedMoves(in: "rook takes e8, then Rxe8 and Nbd2").map(\.text), ["Re8", "Nd2"])
        XCTAssertEqual(AskPrompt.namedMoves(in: "bishop-b4 pins it").map(\.text), ["Bb4"])
    }

    func testIgnoresNonMoves() {
        XCTAssertEqual(AskPrompt.namedMoves(in: "why is the queen so strong? what about e4?"), [])
        XCTAssertEqual(AskPrompt.namedMoves(in: "the queen and d1 are far apart"), [])
    }

    func testLegalSANsForSpoken() throws {
        let start = Position.start
        let n = try XCTUnwrap(AskPrompt.namedMoves(in: "knight to f3").first)
        XCTAssertEqual(AskPrompt.legalSANs(for: n, in: start), ["Nf3"])
        let q = try XCTUnwrap(AskPrompt.namedMoves(in: "queen d1").first)
        XCTAssertEqual(AskPrompt.legalSANs(for: q, in: start), [])
    }

    /// White to move, queen on d3 can go to b5 (check) and d1, but not a8.
    private func subject() throws -> AskPrompt.Subject {
        let pos = try Position(fen: "4k3/8/8/8/8/3Q4/8/4K3 w - - 0 21")
        var s = AskPrompt.Subject(position: pos)
        s.line = ["d3b5", "e8e7"]
        s.evalNow = .cp(580)
        return s
    }

    func testIllegalNamedMoveGetsHelpfulNote() throws {
        // Qd1 would be legal here, so use a move the queen cannot make: Qa8.
        let s = try subject()
        let notes = AskPrompt.illegalMoveNotes(question: "but the engine move seems to be queen a8", subject: s)
        let note = try XCTUnwrap(notes.first)
        XCTAssertTrue(note.text.contains("The player mentioned Qa8, which is not a legal move"))
        XCTAssertTrue(note.text.contains("Legal queen moves here:"))
        XCTAssertTrue(note.text.contains("Qb5+"))
        XCTAssertTrue(note.text.contains("engine's top line here: 21. Qb5+ Ke7"))
        XCTAssertTrue(note.text.contains("+5.80"))
        XCTAssertTrue(note.text.contains("same kind of piece"))
        XCTAssertTrue(note.sans.contains("Qb5+"))
        let prompt = AskPrompt.user(s, turns: [], question: "but the engine move seems to be queen a8")
        XCTAssertTrue(prompt.contains("Note: The player mentioned Qa8"))
        XCTAssertTrue(prompt.range(of: "Note: The player")!.lowerBound < prompt.range(of: "Player's question")!.lowerBound)
    }

    func testLegalNamedMoveGetsNoNote() throws {
        let s = try subject()
        XCTAssertTrue(AskPrompt.illegalMoveNotes(question: "why not queen to d1?", subject: s).isEmpty)
        XCTAssertTrue(AskPrompt.illegalMoveNotes(question: "why not Qb5?", subject: s).isEmpty)
        XCTAssertFalse(AskPrompt.user(s, turns: [], question: "why not Qb5?").contains("Note:"))
    }

    func testLegalInPositionBeforeIsNotFlagged() throws {
        var s = try subject()
        // Qb3 is legal in the earlier position (queen on d3 there), and the current queen sits on d3 too.
        s.before = try Position(fen: "4k3/8/8/8/8/3Q4/8/4K3 w - - 0 21")
        XCTAssertTrue(AskPrompt.illegalMoveNotes(question: "why not Qb3?", subject: s).isEmpty)
    }

    func testSystemPromptTellsModelToSuggestWhatWasMeant() {
        XCTAssertTrue(AskPrompt.system(tool: false).contains("probably meant"))
    }
}
