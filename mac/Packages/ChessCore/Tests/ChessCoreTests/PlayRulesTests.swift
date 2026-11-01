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

    func testEngineHistoryStartsAtLastIrreversibleMove() {
        // e4 is a pawn move: history starts from the position after it; the knight shuffle follows.
        let (g, n) = game("e4 e5 Nf3 Nf6 Ng1 Ng8")
        let h = g.engineHistory(to: n)
        XCTAssertEqual(h.rootFEN, g.nodes[g.path(to: n)[2]].position.fen)   // after ...e5
        XCTAssertEqual(h.moves, ["g1f3", "g8f6", "f3g1", "f6g8"])
        // Root node: no moves.
        let r = g.engineHistory(to: 0)
        XCTAssertEqual(r.rootFEN, g.nodes[0].position.fen)
        XCTAssertEqual(r.moves, [])
        // A capture resets it.
        let (g2, n2) = game("e4 d5 exd5 Qxd5 Nc3 Qd8")
        XCTAssertEqual(g2.engineHistory(to: n2).moves, ["b1c3", "d5d8"])
        // Replaying the history from its root reaches the node's position.
        var p = try! Position(fen: h.rootFEN)
        for u in h.moves { p = try! p.applying(p.move(fromUCI: u)!) }
        XCTAssertEqual(p.fen, g.nodes[n].position.fen)
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

    /// A session's `tip`/`anchor` can outlive its game (New Game while the play banner is still on screen).
    func testStaleNodeIdsAreSafe() {
        let (g, n) = game("e4 e5")
        let fresh = Game()
        XCTAssertEqual(fresh.path(to: n), [])
        XCTAssertEqual(fresh.path(to: -1), [])
        XCTAssertNil(fresh.takeBackTarget(from: n, userSide: .white, anchor: 0))
        XCTAssertNil(fresh.takeBackTarget(from: 0, userSide: .white, anchor: n))
        XCTAssertNil(fresh.gameEnd(at: n))
        XCTAssertEqual(g.path(to: n).count, 3)
    }

    func testStrengthRangeAndOptions() {
        XCTAssertEqual(PlayStrength.eloRange, 1320...3190)
        XCTAssertEqual(PlayStrength.clampedElo(500), 1320)
        XCTAssertEqual(PlayStrength.clampedElo(4000), 3190)
        XCTAssertEqual(PlayStrength.clampedElo(2000), 2000)
        XCTAssertEqual(PlayStrength(elo: 9999).elo, 3190)
        XCTAssertNil(PlayStrength.full.elo)
        XCTAssertEqual(PlayStrength(elo: 1850).title, "Stockfish 1850")
        XCTAssertEqual(PlayStrength.full.title, "Stockfish (full strength)")
        XCTAssertEqual(PlayStrength(elo: 1800).presetLabel, "Club")
        XCTAssertNil(PlayStrength(elo: 1850).presetLabel)
        XCTAssertEqual(PlayStrength.full.uciOptions.first?.value, "false")
        XCTAssertEqual(PlayStrength(elo: 1800).uciOptions.map(\.value), ["true", "1800"])
    }

    func testLegacyPresetMigration() {
        XCTAssertEqual(PlayStrength(legacyPreset: "beginner")?.elo, 1350)
        XCTAssertEqual(PlayStrength(legacyPreset: "club")?.elo, 1800)
        XCTAssertEqual(PlayStrength(legacyPreset: "expert")?.elo, 2200)
        XCTAssertEqual(PlayStrength(legacyPreset: "master")?.elo, 2600)
        XCTAssertEqual(PlayStrength(legacyPreset: "full"), .full)
        XCTAssertNil(PlayStrength(legacyPreset: "nope"))
    }

    /// Stockfish 18 search.h `Skill`: level = clamp(((37.2473e - 40.8525)e + 22.2943)e - 0.311438, 0, 19).
    func testSkillLevelMatchesStockfish() {
        XCTAssertEqual(PlayStrength.skillLevel(forElo: 1320), 0)                       // the fit dips below 0
        XCTAssertEqual(PlayStrength.skillLevel(forElo: 3190), 18.378, accuracy: 0.001)
        XCTAssertEqual(PlayStrength.skillLevel(forElo: 1800), 3.350, accuracy: 0.01)
        XCTAssertEqual(PlayStrength.skillLevel(forElo: 2200), 5.01, accuracy: 0.01)
        XCTAssertEqual(PlayStrength.skillLevel(forElo: 2600), 7.75, accuracy: 0.01)
        XCTAssertNil(PlayStrength.full.skillLevel)
        // Monotonic over the range, so the slider never makes it weaker as it moves right.
        var last = -1.0
        for elo in stride(from: 1320, through: 3190, by: 10) {
            let l = PlayStrength.skillLevel(forElo: elo)
            XCTAssertGreaterThanOrEqual(l, last); last = l
        }
    }

    func testPickDepthAndMoveTime() {
        XCTAssertEqual(PlayStrength(elo: 1320).pickDepth, 1)
        XCTAssertEqual(PlayStrength(elo: 1800).pickDepth, 4)
        XCTAssertEqual(PlayStrength(elo: 2600).pickDepth, 8)
        XCTAssertEqual(PlayStrength(elo: 3190).pickDepth, 19)
        XCTAssertNil(PlayStrength.full.pickDepth)
        XCTAssertEqual(PlayStrength(elo: 1800).moveTime(fullStrengthMillis: 3000), 250)
        XCTAssertEqual(PlayStrength(elo: 3190).moveTime(fullStrengthMillis: 500), 3500)
        XCTAssertEqual(PlayStrength.full.moveTime(fullStrengthMillis: 3000), 3000)
        // Stronger never thinks less.
        var last = 0
        for elo in stride(from: 1320, through: 3190, by: 10) {
            let t = PlayStrength(elo: elo).limitedMoveTime!
            XCTAssertGreaterThanOrEqual(t, last); last = t
        }
    }
}
