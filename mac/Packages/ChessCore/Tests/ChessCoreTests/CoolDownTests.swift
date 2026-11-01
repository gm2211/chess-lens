import XCTest
@testable import ChessCore

final class CoolDownTests: XCTestCase {
    func testPausesWhenHotOrLowPower() {
        var c = CoolDown()
        c.update(thermal: .fair, lowPower: false, enabled: true)
        XCTAssertNil(c.reason)
        c.update(thermal: .serious, lowPower: false, enabled: true)
        XCTAssertEqual(c.reason, .hot)
        c.update(thermal: .nominal, lowPower: true, enabled: true)
        XCTAssertEqual(c.reason, .lowPower)
        c.update(thermal: .critical, lowPower: true, enabled: true)
        XCTAssertEqual(c.reason, .hot)
    }

    func testResumesWhenCleared() {
        var c = CoolDown()
        c.update(thermal: .serious, lowPower: false, enabled: true)
        c.update(thermal: .fair, lowPower: false, enabled: true)
        XCTAssertNil(c.reason)
        XCTAssertNil(c.latched)
    }

    func testDisabledNeverPauses() {
        var c = CoolDown()
        c.update(thermal: .critical, lowPower: true, enabled: false)
        XCTAssertNil(c.reason)
    }

    func testContinueOverridesUntilConditionClears() {
        var c = CoolDown()
        c.update(thermal: .serious, lowPower: false, enabled: true)
        c.continueAnyway()
        XCTAssertNil(c.reason)
        c.update(thermal: .critical, lowPower: false, enabled: true)
        XCTAssertNil(c.reason)                      // still the same episode
        c.update(thermal: .nominal, lowPower: false, enabled: true)
        c.update(thermal: .serious, lowPower: false, enabled: true)
        XCTAssertEqual(c.reason, .hot)              // a new episode pauses again
    }

    func testContinueWithoutConditionIsNoOp() {
        var c = CoolDown()
        c.continueAnyway()
        c.update(thermal: .serious, lowPower: false, enabled: true)
        XCTAssertEqual(c.reason, .hot)
    }

    func testTogglingOffClearsOverride() {
        var c = CoolDown()
        c.update(thermal: .serious, lowPower: false, enabled: true)
        c.continueAnyway()
        c.update(thermal: .serious, lowPower: false, enabled: false)
        c.update(thermal: .serious, lowPower: false, enabled: true)
        XCTAssertEqual(c.reason, .hot)
    }
}

final class EngineConfigTests: XCTestCase {
    func testOldSettingsMigrate() throws {
        let old = #"{"preset":"deep","depthCap":34,"lines":4,"threads":6,"hash":512}"#
        let c = try JSONDecoder().decode(EngineConfig.self, from: Data(old.utf8))
        XCTAssertEqual(c, EngineConfig(lines: 4, threads: 6, hash: 512, pauseWhenHot: true))
    }

    func testRoundTrip() throws {
        let c = EngineConfig(lines: 2, threads: 3, hash: 128, pauseWhenHot: false)
        let back = try JSONDecoder().decode(EngineConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(json.contains("preset")); XCTAssertFalse(json.contains("depthCap"))
    }
}
