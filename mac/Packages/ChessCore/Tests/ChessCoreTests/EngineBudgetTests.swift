import XCTest
@testable import ChessCore

final class EngineBudgetTests: XCTestCase {
    func testRemainingAndExhaustion() {
        var l = EngineBudgetLedger()
        XCTAssertEqual(l.remaining("a", budget: 30), 30)
        l.record("a", elapsed: 12)
        XCTAssertEqual(l.remaining("a", budget: 30), 18)
        l.record("a", elapsed: 18)
        XCTAssertTrue(l.isExhausted("a", budget: 30))
        XCTAssertFalse(l.isExhausted("b", budget: 30))
    }

    func testTimeCountsAcrossRevisits() {
        var l = EngineBudgetLedger()
        l.record("a", elapsed: 10); l.record("b", elapsed: 5); l.record("a", elapsed: 10)
        XCTAssertEqual(l.remaining("a", budget: 30), 10)
        XCTAssertEqual(l.remaining("b", budget: 30), 25)
    }

    func testKeepThinkingGrantsAnotherPeriod() {
        var l = EngineBudgetLedger()
        l.record("a", elapsed: 30)
        XCTAssertTrue(l.isExhausted("a", budget: 30))
        l.extend("a", budget: 30)
        XCTAssertEqual(l.remaining("a", budget: 30), 30)
        l.record("a", elapsed: 30)
        XCTAssertTrue(l.isExhausted("a", budget: 30))
    }

    func testUnlimited() {
        var l = EngineBudgetLedger()
        l.record("a", elapsed: 9999)
        XCTAssertNil(l.remaining("a", budget: 0))
        XCTAssertFalse(l.isExhausted("a", budget: 0))
        // Keep thinking under a limited setting, then Unlimited key sticks.
        l.extend("a", budget: 0)
        XCTAssertNil(l.remaining("a", budget: 30))
    }

    func testChangingBudgetAppliesToSpentTime() {
        var l = EngineBudgetLedger()
        l.record("a", elapsed: 40)
        XCTAssertTrue(l.isExhausted("a", budget: 30))
        XCTAssertEqual(l.remaining("a", budget: 60), 20)
    }

    func testActivityGate() {
        var g = ActivityGate()
        XCTAssertTrue(g.shouldRun)
        g.appActive = false
        XCTAssertFalse(g.shouldRun); XCTAssertTrue(g.showsPausedNote)
        g.appActive = true; g.windowVisible = false
        XCTAssertFalse(g.shouldRun); XCTAssertFalse(g.showsPausedNote)
        g.windowVisible = true; g.screenAwake = false
        XCTAssertFalse(g.shouldRun)
        g.screenAwake = true
        XCTAssertTrue(g.shouldRun)
    }

    func testThreadDefaultsAndMigration() {
        XCTAssertEqual(EngineConfig.defaultThreads(performanceCores: 6), 3)
        XCTAssertEqual(EngineConfig.defaultThreads(performanceCores: 4), 2)
        XCTAssertEqual(EngineConfig.defaultThreads(performanceCores: 2), 2)
        XCTAssertEqual(EngineConfig.defaultThreads(performanceCores: 1), 2)
        XCTAssertEqual(EngineConfig.migratedThreads(saved: 6, performanceCores: 6), 3)
        XCTAssertEqual(EngineConfig.migratedThreads(saved: 5, performanceCores: 6), 5)
        XCTAssertEqual(EngineConfig.migratedThreads(saved: 8, performanceCores: 6), 8)
    }

    func testOldSettingsDecodeWithDefaultBudget() throws {
        let json = #"{"lines":3,"threads":6,"hash":256,"pauseWhenHot":true}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(EngineConfig.self, from: json)
        XCTAssertEqual(c.budgetSeconds, 30)
        XCTAssertEqual(EngineConfig.budgetLabel(300), "5 min")
        XCTAssertEqual(EngineConfig.budgetLabel(0), "Unlimited")
        XCTAssertEqual(EngineConfig.budgetLabel(10), "10 s")
    }
}
