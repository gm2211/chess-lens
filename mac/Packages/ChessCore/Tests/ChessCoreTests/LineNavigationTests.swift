import XCTest
@testable import ChessCore

final class LineNavigationTests: XCTestCase {
    // 1. e4 e5 2. Nf3 (2. Nc3 Nc6 (2... Nf6 3. f4)) Nc6 3. Bb5 *
    private func tree() -> Game {
        PGN.parse("1. e4 e5 2. Nf3 (2. Nc3 Nc6 (2... Nf6 3. f4)) Nc6 3. Bb5 *")[0].game
    }

    /// Node reached by following SAN moves from the root.
    private func node(_ g: Game, _ sans: String...) -> Int {
        var cur = 0
        for s in sans {
            guard let next = g.nodes[cur].children.first(where: { g.nodes[$0].san == s }) else {
                XCTFail("no \(s) after \(cur)"); return cur
            }
            cur = next
        }
        return cur
    }

    func testDisplayLineFollowsTipAndFallsBackToMainline() {
        let g = tree()
        let f4 = node(g, "e4", "e5", "Nc3", "Nf6", "f4")
        XCTAssertEqual(g.displayLine(tip: f4).map { g.nodes[$0].san }, ["", "e4", "e5", "Nc3", "Nf6", "f4"])
        XCTAssertEqual(g.displayLine(tip: 999), g.mainline())
    }

    func testLineTipAfterGoto() {
        let g = tree()
        let mainEnd = g.mainline().last!
        let e5 = node(g, "e4", "e5")
        let nc3 = node(g, "e4", "e5", "Nc3")
        let f4 = node(g, "e4", "e5", "Nc3", "Nf6", "f4")
        let nc6 = node(g, "e4", "e5", "Nc3", "Nc6")
        // On the line: tip kept.
        XCTAssertEqual(g.lineTip(afterGoto: e5, currentTip: mainEnd), mainEnd)
        XCTAssertEqual(g.lineTip(afterGoto: nc3, currentTip: f4), f4)
        // Off the line: end of the first-child continuation.
        XCTAssertEqual(g.lineTip(afterGoto: nc3, currentTip: mainEnd), nc6)
        XCTAssertEqual(g.lineTip(afterGoto: node(g, "e4", "e5", "Nc3", "Nf6"), currentTip: nc6), f4)
        XCTAssertEqual(g.lineTip(afterGoto: node(g, "e4", "e5", "Nf3"), currentTip: f4), mainEnd)
        // Stale id.
        XCTAssertEqual(g.lineTip(afterGoto: 999, currentTip: f4), mainEnd)
    }

    func testNextOnLine() {
        let g = tree()
        let e5 = node(g, "e4", "e5")
        let nc3 = node(g, "e4", "e5", "Nc3")
        let nf6 = node(g, "e4", "e5", "Nc3", "Nf6")
        let f4 = node(g, "e4", "e5", "Nc3", "Nf6", "f4")
        XCTAssertEqual(g.nextOnLine(from: e5, tip: f4), nc3)
        XCTAssertEqual(g.nextOnLine(from: nc3, tip: f4), nf6)   // not children.first (Nc6)
        XCTAssertNil(g.nextOnLine(from: f4, tip: f4))
        XCTAssertNil(g.nextOnLine(from: node(g, "e4", "e5", "Nf3"), tip: f4))
    }

    func testForksOnLine() {
        let g = tree()
        let nf3 = node(g, "e4", "e5", "Nf3")
        let nc3 = node(g, "e4", "e5", "Nc3")
        let nc6 = node(g, "e4", "e5", "Nc3", "Nc6")
        let nf6 = node(g, "e4", "e5", "Nc3", "Nf6")
        let f4 = node(g, "e4", "e5", "Nc3", "Nf6", "f4")
        let forks = g.forks(on: g.displayLine(tip: f4))
        XCTAssertEqual(forks.map(\.node), [nc3, nf6])
        XCTAssertEqual(forks[0].siblings, [nf3, nc3])
        XCTAssertEqual(forks[1].siblings, [nc6, nf6])
        XCTAssertEqual(g.forks(on: g.mainline()).map(\.node), [nf3])
    }

    func testMainlineMembershipAndDeviationPoint() {
        let g = tree()
        let e5 = node(g, "e4", "e5")
        let f4 = node(g, "e4", "e5", "Nc3", "Nf6", "f4")
        XCTAssertTrue(g.isOnMainline(0))
        XCTAssertTrue(g.isOnMainline(e5))
        XCTAssertFalse(g.isOnMainline(f4))
        XCTAssertEqual(g.lastMainlineNode(on: g.displayLine(tip: f4)), e5)
        XCTAssertEqual(g.lastMainlineNode(on: g.mainline()), g.mainline().last)
    }

    func testSiblingCyclingWraps() {
        let g = tree()
        let nf3 = node(g, "e4", "e5", "Nf3")
        let nc3 = node(g, "e4", "e5", "Nc3")
        XCTAssertEqual(g.sibling(of: nf3, offset: 1), nc3)
        XCTAssertEqual(g.sibling(of: nc3, offset: 1), nf3)
        XCTAssertEqual(g.sibling(of: nf3, offset: -1), nc3)
        XCTAssertNil(g.sibling(of: node(g, "e4"), offset: 1))
        XCTAssertNil(g.sibling(of: 0, offset: 1))
    }

    func testLocateMovesSurvivesDelete() {
        var g = tree()
        let f4 = node(g, "e4", "e5", "Nc3", "Nf6", "f4")
        let moves = g.moves(to: f4)
        g.delete(node(g, "e4", "e5", "Nf3"))                      // ids are rebuilt
        let found = g.locate(moves: moves)
        XCTAssertEqual(g.path(to: found).dropFirst().map { g.nodes[$0].san }, ["e4", "e5", "Nc3", "Nf6", "f4"])
        g.delete(node(g, "e4", "e5", "Nc3", "Nf6"))
        XCTAssertEqual(g.nodes[g.locate(moves: moves)].san, "Nc3")
    }
}
