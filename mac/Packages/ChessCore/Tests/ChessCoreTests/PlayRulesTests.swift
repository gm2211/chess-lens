import XCTest
@testable import ChessCore

final class PlayRulesTests: XCTestCase {
    private func game(_ san: String) -> (Game, Int) {
        var g = Game()
        var cur = 0
        for token in san.split(separator: " ") {
            let m = try! g.nodes[cur].position.parseSAN(String(token))
            cur = try! g.addMove(m, after: cur)
        }
        return (g, cur)
    }

    func testCheckmateAndStalemate() {
        let (g, n) = game("f3 e5 g4 Qh4")
        XCTAssertEqual(g.gameEnd(at: n), .checkmate(winner: .black))
        XCTAssertEqual(g.gameEnd(at: n)?.pgnResult, "0-1")
        let stale = try! Position(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
        XCTAssertEqual(stale.gameEnd, .stalemate)
        XCTAssertTrue(stale.gameEnd!.isDraw)
    }

    func testInsufficientAndFiftyMove() {
        XCTAssertEqual(try! Position(fen: "8/8/4k3/8/8/3K4/8/8 w - - 0 1").gameEnd, .insufficientMaterial)
        XCTAssertEqual(try! Position(fen: "8/8/4k3/8/8/3K4/R7/8 w - - 100 80").gameEnd, .fiftyMoveRule)
        XCTAssertNil(try! Position(fen: "8/8/4k3/8/8/3K4/R7/8 w - - 99 80").gameEnd)
    }

    func testThreefoldRepetition() {
        let (g, n) = game("Nf3 Nf6 Ng1 Ng8 Nf3 Nf6 Ng1 Ng8")
        XCTAssertEqual(g.gameEnd(at: n), .threefoldRepetition)
        let (g2, n2) = game("Nf3 Nf6 Ng1 Ng8")
        XCTAssertNil(g2.gameEnd(at: n2))
    }

    func testTakeBackTarget() {
        let (g, n) = game("e4 e5 Nf3 Nc6")                    // White to move at n
        let ids = g.path(to: n)                              // root, e4, e5, Nf3, Nc6
        // White (user) to move: back to the previous White turn, i.e. before Nf3.
        XCTAssertEqual(g.takeBackTarget(from: n, userSide: .white, anchor: 0), ids[2])
        // Engine (Black) to move after Nf3: undo the user's Nf3 too.
        XCTAssertEqual(g.takeBackTarget(from: ids[3], userSide: .white, anchor: 0), ids[2])
        // Never before the anchor.
        XCTAssertEqual(g.takeBackTarget(from: n, userSide: .white, anchor: ids[2]), ids[2])
        XCTAssertNil(g.takeBackTarget(from: n, userSide: .white, anchor: ids[3]))
        XCTAssertEqual(g.takeBackTarget(from: n, userSide: .white, anchor: ids[1]), ids[2])
        // User is Black: from e4 (Black to move) there is no earlier Black turn.
        XCTAssertNil(g.takeBackTarget(from: ids[1], userSide: .black, anchor: 0))
        XCTAssertEqual(g.takeBackTarget(from: ids[4], userSide: .black, anchor: 0), ids[3])
        // An unrelated anchor yields nothing.
        var g2 = g
        let other = try! g2.addMove(Position.start.legalMoves().first { Sq.name($0.to) == "d4" }!, after: 0)
        XCTAssertNil(g2.takeBackTarget(from: n, userSide: .white, anchor: other))
    }

    func testStrengthMapping() {
        XCTAssertEqual(PlayStrength.eloRange, 1320...3190)
        XCTAssertEqual(PlayStrength.clampedElo(500), 1320)
        XCTAssertEqual(PlayStrength.clampedElo(4000), 3190)
        XCTAssertEqual(PlayStrength.clampedElo(2000), 2000)
        for s in PlayStrength.allCases { if let e = s.elo { XCTAssertTrue(PlayStrength.eloRange.contains(e)) } }
        XCTAssertNil(PlayStrength.full.elo)
        XCTAssertEqual(PlayStrength.club.detail, "Club (1800)")
        XCTAssertEqual(PlayStrength.full.uciOptions.first?.value, "false")
        XCTAssertEqual(PlayStrength.club.uciOptions.map(\.value), ["true", "1800"])
    }
}
