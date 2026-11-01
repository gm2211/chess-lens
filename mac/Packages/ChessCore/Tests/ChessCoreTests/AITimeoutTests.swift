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

    /// Silent for `lead`, then `items` every `gap`, then finishes (or hangs when `hang`).
    private func slowStart(lead: Duration, items: [String], gap: Duration = .milliseconds(10), hang: Bool = false,
                           heartbeat: AIHeartbeat? = nil, beatEvery: Duration? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            let t = Task {
                if let heartbeat, let beatEvery {
                    var waited = Duration.zero
                    while waited < lead { try? await Task.sleep(for: beatEvery); heartbeat.pulse(); waited += beatEvery }
                } else { try? await Task.sleep(for: lead) }
                for i in items { c.yield(i); try? await Task.sleep(for: gap) }
                if !hang { c.finish() }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }

    func testSilentThenStreamingPassesWhenWithinFirstChunk() async throws {
        // 250 ms of silence is over the 100 ms inactivity window but inside the 600 ms first-chunk window.
        let out = try await collect(withInactivityTimeout(slowStart(lead: .milliseconds(250), items: ["a", "b", "c"]),
                                                          firstChunk: .milliseconds(600), inactivity: .milliseconds(100)))
        XCTAssertEqual(out, ["a", "b", "c"])
    }

    func testNeverSpeakingTimesOutAtFirstChunk() async {
        let start = ContinuousClock.now
        do {
            _ = try await collect(withInactivityTimeout(fake([], hang: true), firstChunk: .milliseconds(300), inactivity: .milliseconds(80)))
            XCTFail("should time out")
        } catch let e as AITimedOut { XCTAssertEqual(e.kind, .inactive) } catch { XCTFail("\(error)") }
        let took = ContinuousClock.now - start
        XCTAssertGreaterThan(took, .milliseconds(250), "must wait out the first-chunk window, not the inactivity one")
        XCTAssertLessThan(took, .seconds(2))
    }

    func testMidStreamStallFailsEvenAfterALongFirstChunkWindow() async {
        var got: [String] = []
        let start = ContinuousClock.now
        do {
            for try await v in withInactivityTimeout(slowStart(lead: .milliseconds(100), items: ["a"], hang: true),
                                                     firstChunk: .seconds(5), inactivity: .milliseconds(150)) { got.append(v) }
            XCTFail("should time out")
        } catch let e as AITimedOut { XCTAssertEqual(e.kind, .inactive) } catch { XCTFail("\(error)") }
        XCTAssertEqual(got, ["a"])
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "after the first chunk the short window applies")
    }

    func testOverallCapBeatsALongFirstChunkWindow() async {
        do {
            _ = try await collect(withInactivityTimeout(fake([], hang: true), firstChunk: .seconds(10), inactivity: .seconds(10),
                                                        overall: .milliseconds(150)))
            XCTFail("should time out")
        } catch let e as AITimedOut { XCTAssertEqual(e.kind, .overall) } catch { XCTFail("\(error)") }
    }

    func testHeartbeatsKeepAQuietStartAliveButDoNotStartTheStream() async throws {
        // Pulses every 40 ms for 400 ms, then text. firstChunk equals inactivity (100 ms): only the pulses save it.
        let beat = AIHeartbeat()
        let out = try await collect(withInactivityTimeout(
            slowStart(lead: .milliseconds(400), items: ["a"], heartbeat: beat, beatEvery: .milliseconds(40)),
            firstChunk: .milliseconds(100), inactivity: .milliseconds(100), heartbeat: beat))
        XCTAssertEqual(out, ["a"])
    }

    func testHeartbeatsStillEndAtTheOverallCap() async {
        let beat = AIHeartbeat()
        do {
            _ = try await collect(withInactivityTimeout(
                slowStart(lead: .seconds(30), items: [], heartbeat: beat, beatEvery: .milliseconds(30)),
                firstChunk: .milliseconds(100), inactivity: .milliseconds(100), overall: .milliseconds(300), heartbeat: beat))
            XCTFail("should time out")
        } catch let e as AITimedOut { XCTAssertEqual(e.kind, .overall) } catch { XCTFail("\(error)") }
    }

    func testDefaultsGiveReasoningModelsTimeToThink() {
        XCTAssertEqual(AITimeout.lesson, AITimeout(firstChunk: .seconds(150), inactivity: .seconds(45), overall: .seconds(300)))
        XCTAssertEqual(AITimeout.note, AITimeout(firstChunk: .seconds(90), inactivity: .seconds(45), overall: .seconds(150)))
        XCTAssertEqual(AITimeout.ask, AITimeout(firstChunk: .seconds(90), inactivity: .seconds(45), overall: .seconds(150)))
    }

    func testWaitText() {
        XCTAssertEqual(AIWaitText.line(note: nil, provider: "Grok", seconds: 2), "Grok is thinking\u{2026}")
        XCTAssertEqual(AIWaitText.line(note: nil, provider: "Grok", seconds: 25), "Grok is thinking\u{2026} 25 s")
        XCTAssertEqual(AIWaitText.line(note: nil, provider: "Grok", seconds: 65), "Grok is thinking\u{2026} 1 min 5 s")
        XCTAssertEqual(AIWaitText.line(note: "Switched.", provider: "Grok", seconds: 30), "Switched. 30 s")
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
