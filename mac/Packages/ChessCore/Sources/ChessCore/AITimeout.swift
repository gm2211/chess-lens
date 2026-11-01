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

/// How long an AI request may stay silent, and how long it may run in all.
public struct AITimeout: Equatable, Sendable {
    public var inactivity: Duration
    public var overall: Duration

    public init(inactivity: Duration, overall: Duration) {
        self.inactivity = inactivity
        self.overall = overall
    }

    /// The lesson on the whole game: long answer, several engine rounds.
    public static let lesson = AITimeout(inactivity: .seconds(45), overall: .seconds(180))
    /// One moment's note.
    public static let note = AITimeout(inactivity: .seconds(45), overall: .seconds(90))
    /// One Ask AI answer.
    public static let ask = AITimeout(inactivity: .seconds(45), overall: .seconds(90))
}

/// Re-emits `upstream`, but fails with `AITimedOut` when no element arrives for `inactivity`, or when more than
/// `overall` has passed since the call. Cancels `upstream` on timeout (and when the consumer stops listening), so a
/// request behind it (the sidecar's) is cancelled too. The clock starts at the call, so a request that never
/// produces a first element times out as well.
public func withInactivityTimeout<T: Sendable>(
    _ upstream: AsyncThrowingStream<T, Error>, inactivity: Duration, overall: Duration? = nil
) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            let clock = ContinuousClock()
            let start = clock.now
            let activity = AIActivity(start)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await value in upstream {
                            await activity.touch(clock.now)
                            continuation.yield(value)
                        }
                    }
                    group.addTask {
                        while true {
                            let last = await activity.last
                            var due = last.advanced(by: inactivity)
                            if let overall { due = min(due, start.advanced(by: overall)) }
                            try await clock.sleep(until: due)
                            let now = clock.now
                            if let overall, now >= start.advanced(by: overall) { throw AITimedOut(.overall) }
                            if now >= (await activity.last).advanced(by: inactivity) { throw AITimedOut(.inactive) }
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

private actor AIActivity {
    private(set) var last: ContinuousClock.Instant
    init(_ start: ContinuousClock.Instant) { last = start }
    func touch(_ now: ContinuousClock.Instant) { last = now }
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
