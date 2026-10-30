import XCTest
@testable import ChessCore

final class CoachPromptTests: XCTestCase {
    func testPromptContents() throws {
        let g = PGN.parse("1. e4 e5 2. Nf3 Nc6 *")[0].game
        let n = g.nodes
        XCTAssertEqual(n.count, 5)
        let before = n[3].position
        let move = try XCTUnwrap(n[4].move)
        let p = CoachPrompt.user(before: before, move: move, classification: "mistake",
                                 evalBefore: .cp(30), evalAfter: .cp(150), tags: [.allowsFork],
                                 refutation: ["f1b5", "g8f6"], best: ["b8c6", "f1b5", "a7a6", "b5a4", "g8f6"],
                                 history: ["e4", "e5", "Nf3"])
        XCTAssertTrue(p.contains(before.fen))
        XCTAssertTrue(p.contains("Move played: 2\u{2026} Nc6 (mistake)"))
        // Black moved: White-POV +0.30 / +1.50 becomes -0.30 / -1.50.
        XCTAssertTrue(p.contains("-0.30 before, -1.50 after"))
        XCTAssertTrue(p.contains("allows a fork"))
        XCTAssertTrue(p.contains("3. Bb5 Nf6"))
        XCTAssertTrue(p.contains("2\u{2026} Nc6 3. Bb5 a6 4. Ba4 Nf6"))
        XCTAssertTrue(p.contains("Game so far: 1. e4 e5 2. Nf3"))
    }

    func testPlyCapAndEmptyHistory() throws {
        let start = Position.start
        let m = try XCTUnwrap(start.move(fromUCI: "e2e4"))
        let line = ["e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5a4", "g8f6", "e1g1", "f8e7", "f1e1"]
        let p = CoachPrompt.user(before: start, move: m, classification: nil, evalBefore: nil, evalAfter: nil,
                                 tags: [], refutation: line, best: [], history: [])
        XCTAssertTrue(p.contains("Game so far: (start of game)"))
        XCTAssertTrue(p.contains("e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6"))
        XCTAssertTrue(p.contains("5. O-O"))
        XCTAssertFalse(p.contains("Be7"))
        XCTAssertFalse(p.contains("Tags:"))
    }
}
