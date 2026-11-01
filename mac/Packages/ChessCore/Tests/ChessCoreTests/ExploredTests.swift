import XCTest
@testable import ChessCore

final class ExploredTests: XCTestCase {
    // 1. e4 e5 2. Nf3 (2. Nc3) Nc6 *   (imported, one imported variation)
    private func base() -> Game {
        PGN.parse("1. e4 e5 2. Nf3 (2. Nc3) Nc6 *")[0].game
    }

    private func find(_ g: Game, _ sans: String...) -> Int {
        var cur = 0
        for s in sans { cur = g.nodes[cur].children.first { g.nodes[$0].san == s }! }
        return cur
    }

    private func play(_ g: inout Game, _ uci: String, after: Int, explored: Bool = true) -> Int {
        let m = g.nodes[after].position.move(fromUCI: uci)!
        return try! g.addMove(m, after: after, explored: explored)
    }

    func testImportedNodesAreNotExplored() {
        XCTAssertFalse(base().nodes.contains { $0.explored })
        var g = Game()
        let id = try! g.addMove(g.startPosition.move(fromUCI: "e2e4")!, after: 0)
        XCTAssertFalse(g.nodes[id].explored)
    }

    func testClearExploredKeepsImportedVariationsAndRemapsIds() {
        var g = base()
        let nf3 = find(g, "e4", "e5", "Nf3")
        let nc3 = find(g, "e4", "e5", "Nc3")
        let nc6 = find(g, "e4", "e5", "Nf3", "Nc6")
        let a = play(&g, "g8f6", after: find(g, "e4", "e5", "Nc3"))       // explored on imported variation
        let b = play(&g, "d7d5", after: find(g, "e4"))                   // explored side line off 1.e4
        let c = play(&g, "c2c4", after: nc6)                              // trailing past the main line
        XCTAssertEqual(g.exploredCount, 3)
        _ = (a, b, c, nf3)
        let tip = c
        let (removed, remap) = g.clearExplored()
        XCTAssertEqual(removed, 3)
        XCTAssertEqual(g.nodes.count, 6)
        XCTAssertFalse(g.nodes.contains { $0.explored })
        XCTAssertNil(remap[tip])
        XCTAssertNotNil(remap[nc3])
        XCTAssertEqual(g.nodes[remap[nc6]!].san, "Nc6")
        XCTAssertEqual(g.nodes[remap[nc3]!].san, "Nc3")
        XCTAssertEqual(g.mainlineSAN, ["e4", "e5", "Nf3", "Nc6"])
        for n in g.nodes { XCTAssertEqual(n.id, g.nodes.firstIndex { $0.id == n.id }) }
        XCTAssertEqual(g.exploredCount, 0)
    }

    func testPromotedExploredMoveStillCleared() {
        var g = base()
        let d = play(&g, "d7d5", after: find(g, "e4"))
        g.promote(d)
        XCTAssertTrue(g.nodes[d].explored)           // promote keeps flags
        XCTAssertEqual(g.mainlineSAN, ["e4", "d5"])
        g.clearExplored()
        XCTAssertEqual(g.mainlineSAN, ["e4", "e5", "Nf3", "Nc6"])
    }

    func testExploredSignatureSurvivesPGNRoundTrip() {
        var g = base()
        _ = play(&g, "d7d5", after: find(g, "e4"))
        _ = play(&g, "c2c4", after: find(g, "e4", "e5", "Nf3", "Nc6"))
        let sig = g.exploredSignature
        var back = PGN.parse(PGN.export(g))[0].game
        XCTAssertFalse(back.nodes.contains { $0.explored })
        back.applyExploredSignature(sig)
        XCTAssertEqual(back.exploredSignature, sig)
        XCTAssertEqual(back.exploredCount, 2)
        back.applyExploredSignature("1")              // wrong size: ignored
        XCTAssertEqual(back.exploredSignature, sig)
    }

    func testOldSaveWithoutExploredDecodesWithDefault() throws {
        struct Saved: Codable {
            var pgn: String; var path: [Int]; var flipped: Bool
            var tip: [Int]? = nil
            var explored: String? = nil
        }
        let old = #"{"pgn":"1. e4 *","path":[0],"flipped":false}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(Saved.self, from: old)
        XCTAssertNil(s.explored)
    }
}
