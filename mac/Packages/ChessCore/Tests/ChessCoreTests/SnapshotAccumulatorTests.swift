import XCTest
@testable import ChessCore

final class SnapshotAccumulatorTests: XCTestCase {
    private func info(_ s: String) -> UCIInfo { UCI.parseInfo(s)! }
    private func line(depth: Int, pv: Int, cp: Int, move: String = "e2e4", bound: String = "", nodes: Int = 1000) -> UCIInfo {
        info("info depth \(depth) seldepth \(depth) multipv \(pv) score cp \(cp)\(bound) nodes \(nodes) nps 500000 time 10 pv \(move) e7e5")
    }

    func testEmitsOncePerDepthWithAllPVs() {
        var acc = SnapshotAccumulator(expectedPVs: 3)
        XCTAssertNil(acc.accumulate(line(depth: 1, pv: 1, cp: 30)))
        XCTAssertNil(acc.accumulate(line(depth: 1, pv: 2, cp: 20)))
        let s1 = acc.accumulate(line(depth: 1, pv: 3, cp: 10))
        XCTAssertEqual(s1?.depth, 1)
        XCTAssertEqual(s1?.pvs.count, 3)
        XCTAssertNil(acc.accumulate(line(depth: 2, pv: 1, cp: 31)))
        XCTAssertNil(acc.accumulate(line(depth: 2, pv: 2, cp: 21)))
        XCTAssertEqual(acc.accumulate(line(depth: 2, pv: 3, cp: 11))?.depth, 2)
    }

    func testIgnoresSkippedDepthForPrimary() {
        var acc = SnapshotAccumulator(expectedPVs: 1)
        XCTAssertNotNil(acc.accumulate(line(depth: 1, pv: 1, cp: 10)))
        XCTAssertNil(acc.accumulate(line(depth: 3, pv: 1, cp: 10)))
        XCTAssertEqual(acc.accumulate(line(depth: 2, pv: 1, cp: 12))?.depth, 2)
    }

    func testIgnoresPrimaryBoundLines() {
        var acc = SnapshotAccumulator(expectedPVs: 1)
        XCTAssertNil(acc.accumulate(line(depth: 1, pv: 1, cp: 10, bound: " lowerbound")))
        XCTAssertNil(acc.accumulate(line(depth: 1, pv: 1, cp: 10, bound: " upperbound")))
        XCTAssertEqual(acc.accumulate(line(depth: 1, pv: 1, cp: 10))?.depth, 1)
    }

    func testFewerLegalMovesThanMultiPV() {
        // Caller caps expected PVs by the number of legal moves.
        var acc = SnapshotAccumulator(expectedPVs: 2)
        XCTAssertNil(acc.accumulate(line(depth: 5, pv: 1, cp: 50)))
        XCTAssertEqual(acc.accumulate(line(depth: 5, pv: 2, cp: -50))?.pvs.count, 2)
    }

    func testLearnsWhenEngineSendsFewerThanExpected() {
        var acc = SnapshotAccumulator(expectedPVs: 3)
        _ = acc.accumulate(line(depth: 1, pv: 1, cp: 5))
        _ = acc.accumulate(line(depth: 1, pv: 2, cp: 4))
        // depth 2 starts without a third PV at depth 1: expectation drops to 2
        XCTAssertNil(acc.accumulate(line(depth: 2, pv: 1, cp: 5)))
        XCTAssertEqual(acc.accumulate(line(depth: 2, pv: 2, cp: 4))?.pvs.count, 2)
        XCTAssertEqual(acc.expectedPVs, 2)
    }

    func testRankedSortsBySideToMoveEval() {
        var acc = SnapshotAccumulator(expectedPVs: 3)
        _ = acc.accumulate(line(depth: 4, pv: 1, cp: 20, move: "a"))
        _ = acc.accumulate(line(depth: 4, pv: 2, cp: 90, move: "b"))
        let s = acc.accumulate(info("info depth 4 multipv 3 score mate 2 nodes 9 pv c"))!
        XCTAssertEqual(s.ranked.map { $0.pv[0] }, ["c", "b", "a"])
        XCTAssertEqual(s.nodes, 1000)
    }
}
