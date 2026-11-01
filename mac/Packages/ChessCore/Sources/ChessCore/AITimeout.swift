import Foundation

/// Why an AI request was given up on.
public struct AITimedOut: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Nothing (no token, no event) arrived for the inactivity window.
        case inactive
        /// The request ran past its overall cap.
        case overall
    }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
}

/// How long an AI request may stay silent, and how long it may run in all. Reasoning models think for a long time
/// before their first word, so the wait for the first chunk is longer than the gap allowed between chunks.
public struct AITimeout: Equatable, Sendable {
    /// Silence allowed before the first chunk (a model reasoning before it answers).
    public var firstChunk: Duration
    /// Silence allowed between chunks once the answer is streaming.
    public var inactivity: Duration
    public var overall: Duration

    public init(firstChunk: Duration, inactivity: Duration, overall: Duration) {
        self.firstChunk = firstChunk
        self.inactivity = inactivity
        self.overall = overall
    }

    /// The lesson on the whole game: long answer, several engine rounds.
    public static let lesson = AITimeout(firstChunk: .seconds(150), inactivity: .seconds(45), overall: .seconds(300))
    /// One moment's note.
    public static let note = AITimeout(firstChunk: .seconds(90), inactivity: .seconds(45), overall: .seconds(150))
    /// One Ask AI answer.
    public static let ask = AITimeout(firstChunk: .seconds(90), inactivity: .seconds(45), overall: .seconds(150))
}

/// Lets the source of a stream say "still working" without producing text (a reasoning delta, a progress event).
/// A pulse counts as activity for the inactivity window, but does not end the wait for the first chunk.
public final class AIHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPulse: ContinuousClock.Instant?
    public init() {}
    public func pulse() { lock.lock(); lastPulse = ContinuousClock.now; lock.unlock() }
    var last: ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return lastPulse }
}

/// Re-emits `upstream`, but fails with `AITimedOut` when it goes quiet for too long, or runs past `overall`:
/// - before the first element: `firstChunk` of silence (default `inactivity`), counted from the last heartbeat at
///   the earliest `inactivity` after it;
/// - after it: `inactivity` since the last element or heartbeat;
/// - `overall` since the call, whatever else happens.
/// Cancels `upstream` on timeout (and when the consumer stops listening), so a request behind it (the sidecar's) is
/// cancelled too. The clock starts at the call, so a request that never produces a first element times out as well.
public func withInactivityTimeout<T: Sendable>(
    _ upstream: AsyncThrowingStream<T, Error>, firstChunk: Duration? = nil, inactivity: Duration,
    overall: Duration? = nil, heartbeat: AIHeartbeat? = nil
) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            let state = AIActivity(start)
            let beat = heartbeat ?? AIHeartbeat()
            let first = firstChunk ?? inactivity
            /// When the request is out of time, and why.
            func deadline() -> (due: ContinuousClock.Instant, kind: AITimedOut.Kind) {
                let chunk = state.snapshot
                var last = chunk.last
                if let p = beat.last, p > last { last = p }
                var due = last.advanced(by: inactivity)
                if !chunk.gotFirst { due = max(due, start.advanced(by: first)) }
                if let overall, start.advanced(by: overall) <= due { return (start.advanced(by: overall), .overall) }
                return (due, .inactive)
            }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await value in upstream {
                            state.touch(clock.now)
                            continuation.yield(value)
                        }
                    }
                    group.addTask {
                        while true {
                            // Wake in slices so a deadline that moved earlier (the first chunk arrived) is noticed promptly.
                            try await clock.sleep(until: min(deadline().due, clock.now.advanced(by: inactivity / 4)))
                            let d = deadline()
                            if clock.now >= d.due { throw AITimedOut(d.kind) }
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Runs `operation`, failing with `AITimedOut(.overall)` if it takes longer than `limit`. The operation is cancelled.
public func withTimeout<T: Sendable>(_ limit: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw AITimedOut(.overall)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

private final class AIActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ContinuousClock.Instant
    private var gotFirst = false
    init(_ start: ContinuousClock.Instant) { last = start }
    func touch(_ now: ContinuousClock.Instant) { lock.lock(); last = now; gotFirst = true; lock.unlock() }
    var snapshot: (last: ContinuousClock.Instant, gotFirst: Bool) { lock.lock(); defer { lock.unlock() }; return (last, gotFirst) }
}

/// What a piece of AI work is doing, for deciding whether a model switch should restart it.
public enum AIJobPhase: Equatable, Sendable {
    /// Never asked for.
    case idle
    case running
    case failed
    /// Stopped because no provider was signed in.
    case needsSignIn
    case done
}

public enum AIRetry {
    /// A switch restarts work that is in flight or stopped short, never work that already succeeded or was never asked for.
    public static func restartsOnSwitch(_ phase: AIJobPhase) -> Bool {
        switch phase {
        case .running, .failed, .needsSignIn: true
        case .idle, .done: false
        }
    }

    /// The jobs to restart, in the order given.
    public static func restart<ID: Hashable>(_ jobs: [(id: ID, phase: AIJobPhase)]) -> [ID] {
        jobs.filter { restartsOnSwitch($0.phase) }.map(\.id)
    }

    /// Notes to (re)generate after a switch: those restarting, plus any of `wanted` (the automatic set) not done yet.
    public static func notesToRun<ID: Hashable>(_ jobs: [(id: ID, phase: AIJobPhase)], wanted: [ID], batchWasRunning: Bool) -> [ID] {
        var ids = restart(jobs)
        guard batchWasRunning else { return ids }
        let done = Set(jobs.filter { $0.phase == .done }.map(\.id))
        for id in wanted where !done.contains(id) && !ids.contains(id) { ids.append(id) }
        return ids
    }
}

/// The line shown while waiting for a model's first word.
public enum AIWaitText {
    /// "Grok is thinking…", or "Grok is thinking… 25 s" once it has taken a few seconds; `note` (a model switch) replaces
    /// the first part. Minutes read as "1 min 5 s".
    public static func line(note: String?, provider: String, seconds: Int) -> String {
        let base = note ?? "\(provider) is thinking\u{2026}"
        guard seconds >= 5 else { return base }
        let t = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
        return "\(base) \(t)"
    }
}

/// Plain-language failure lines for the AI surfaces.
public enum AIFailureText {
    public static func timedOut(_ kind: AITimedOut.Kind, provider: String) -> String {
        switch kind {
        case .inactive: "\(provider) didn\u{2019}t respond."
        case .overall: "\(provider) is taking too long."
        }
    }
    public static func notSignedIn(provider: String) -> String { "Not signed in to \(provider)." }
    public static let cancelled = "The request was cancelled."
}
