import XCTest
@testable import ChessCore

final class LineTagTests: XCTestCase {
    func tags(_ fen: String, _ uci: String, ref: [String] = [], best: [String] = [], eval: Eval? = nil) throws -> [LineTag] {
        try Position(fen: fen).lineTags(played: Move(uci: uci)!, refutation: ref, best: best, evalAfter: eval)
    }

    func testHangingPiece() throws {
        // Nd4-f5 walks into ...gxf5 with nothing to recapture.
        let t = try tags("4k3/8/6p1/8/3N4/8/8/4K3 w - - 0 1", "d4f5", ref: ["g6f5"])
        XCTAssertEqual(t, [.hangs(.knight, Sq.parse("f5")!)])
        XCTAssertEqual(t.first?.text, "hangs the knight on f5")
    }

    func testDefendedEvenTradeIsNotHanging() throws {
        // Ne3-f5 is guarded by the e4 pawn; ...Nxf5 exf5 is an even trade.
        XCTAssertEqual(try tags("4k3/8/3n4/8/4P3/4N3/8/4K3 w - - 0 1", "e3f5", ref: ["d6f5"]), [])
    }

    func testFork() throws {
        // After h3, ...Nd3+ forks Ke1 and Rb2.
        XCTAssertEqual(try tags("4k3/8/8/2n5/8/8/1R5P/4K3 w - - 0 1", "h2h3", ref: ["c5d3"]), [.allowsFork])
    }

    func testMateFromEval() throws {
        XCTAssertEqual(try tags("4k3/8/8/8/8/8/8/4K2R w - - 0 1", "h1h2", eval: .mate(-3)), [.allowsMate(3)])
        XCTAssertEqual(try tags("4k3/8/8/8/8/8/8/4K2R w - - 0 1", "h1h2", eval: .mate(3)), [])
    }

    func testMissedCapture() throws {
        XCTAssertEqual(try tags("4k3/8/8/3n4/8/8/8/3QK3 w - - 0 1", "e1f1", best: ["d1d5"]),
                       [.missesCapture(.knight, Sq.parse("d5")!)])
    }
}
