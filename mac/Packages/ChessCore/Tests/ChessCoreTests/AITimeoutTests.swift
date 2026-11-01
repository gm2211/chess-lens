import XCTest
@testable import ChessCore

final class AITimeoutTests: XCTestCase {
    private func collect(_ s: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await v in s { out.append(v) }
        return out
    }

    /// Emits `items` with `gap` between them, then finishes (or hangs forever when `hang`). `cancelled` flips when the stream is torn down.
    private func fake(_ items: [String], gap: Duration = .milliseconds(10), hang: Bool = false,
                      cancelled: Flag = Flag()) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            let t = Task {
                for i in items { try? await Task.sleep(for: gap); c.yield(i) }
                if !hang { c.finish() }
            }
            c.onTermination = { reason in
                if case .cancelled = reason { cancelled.set() }
                t.cancel()
            }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    func testPassesThroughAHealthyStream() async throws {
        let out = try await collect(withInactivityTimeout(fake(["a", "b", "c"]), inactivity: .milliseconds(300)))
        XCTAssertEqual(out, ["a", "b", "c"])
    }

    func testSlowButSteadyStreamIsNotInactive() async throws {
        let items = Array(repeating: "x", count: 8)
        let out = try await collect(withInactivityTimeout(fake(items, gap: .milliseconds(40)), inactivity: .milliseconds(150)))
        XCTAssertEqual(out.count, 8)
    }

    func testSilentStreamTimesOutAndCancelsUpstream() async {
        let flag = Flag()
        let start = ContinuousClock.now
        do {
            _ = try await collect(withInactivityTimeout(fake([], hang: true, cancelled: flag), inactivity: .milliseconds(100)))
            XCTFail("should time out")
        } catch let e as AITimedOut {
            XCTAssertEqual(e.kind, .inactive)
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(flag.value, "the request behind the stream must be cancelled")
    }

    func testStallAfterSomeTokensTimesOut() async {
        var got: [String] = []
        do {
            for try await v in withInactivityTimeout(fake(["a", "b"], hang: true), inactivity: .milliseconds(100)) { got.append(v) }
            XCTFail("should time out")
        } catch let e as AITimedOut { XCTAssertEqual(e.kind, .inactive) } catch { XCTFail("\(error)") }
        XCTAssertEqual(got, ["a", "b"])
    }

    func testOverallCapStopsATrickle() async {
        let items = Array(repeating: "x", count: 100)
        do {
            _ = try await collect(withInactivityTimeout(fake(items, gap: .milliseconds(20)), inactivity: .milliseconds(200),
                                                        overall: .milliseconds(150)))
            XCTFail("should time out")
        } catch let e as AITimedOut { XCTAssertEqual(e.kind, .overall) } catch { XCTFail("\(error)") }
    }

    func testUpstreamErrorPropagates() async {
        struct Boom: Error {}
        let s = AsyncThrowingStream<String, Error> { $0.finish(throwing: Boom()) }
        do { _ = try await collect(withInactivityTimeout(s, inactivity: .seconds(1))); XCTFail() }
        catch is Boom {} catch { XCTFail("\(error)") }
    }

    func testWithTimeout() async throws {
        let v = try await withTimeout(.seconds(1)) { 7 }
        XCTAssertEqual(v, 7)
        do {
            _ = try await withTimeout(.milliseconds(50)) { () -> Int in try await Task.sleep(for: .seconds(10)); return 1 }
            XCTFail()
        } catch let e as AITimedOut { XCTAssertEqual(e.kind, .overall) } catch { XCTFail("\(error)") }
    }

    // MARK: Retry on model switch

    func testSwitchRestartsOnlyUnfinishedWork() {
        XCTAssertTrue(AIRetry.restartsOnSwitch(.running))
        XCTAssertTrue(AIRetry.restartsOnSwitch(.failed))
        XCTAssertTrue(AIRetry.restartsOnSwitch(.needsSignIn))
        XCTAssertFalse(AIRetry.restartsOnSwitch(.done))
        XCTAssertFalse(AIRetry.restartsOnSwitch(.idle))
    }

    func testRestartKeepsSucceededNotes() {
        let jobs: [(id: Int, phase: AIJobPhase)] = [(1, .done), (2, .failed), (3, .running), (4, .idle)]
        XCTAssertEqual(AIRetry.restart(jobs), [2, 3])
    }

    func testBatchRestartAlsoCoversNotesNotStartedYet() {
        let jobs: [(id: Int, phase: AIJobPhase)] = [(1, .done), (2, .running)]
        XCTAssertEqual(AIRetry.notesToRun(jobs, wanted: [1, 2, 5, 6], batchWasRunning: true), [2, 5, 6])
        XCTAssertEqual(AIRetry.notesToRun(jobs, wanted: [1, 2, 5, 6], batchWasRunning: false), [2])
    }

    func testFailureText() {
        XCTAssertEqual(AIFailureText.timedOut(.inactive, provider: "Grok"), "Grok didn\u{2019}t respond.")
        XCTAssertEqual(AIFailureText.notSignedIn(provider: "ChatGPT"), "Not signed in to ChatGPT.")
    }
}
