import Foundation

/// Per-position time budget accounting for live analysis. Time spent counts across revisits of the same
/// position (keyed by the engine cache key), so bouncing back and forth never restarts a full budget.
public struct EngineBudgetLedger: Equatable, Sendable {
    /// Below this many seconds left a position counts as finished.
    public static let epsilon: TimeInterval = 0.25

    private var spent: [String: TimeInterval] = [:]
    /// Absolute spent-seconds cap granted by "Keep thinking" (spent-at-click + one budget).
    private var extended: [String: TimeInterval] = [:]
    private var unlimitedKeys: Set<String> = []
    private let maxKeys = 2000

    public init() {}

    public func spentTime(_ key: String) -> TimeInterval { spent[key] ?? 0 }

    public mutating func record(_ key: String, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        if spent[key] == nil, spent.count >= maxKeys { spent.removeAll(); extended.removeAll(); unlimitedKeys.removeAll() }
        spent[key, default: 0] += elapsed
    }

    /// Seconds left for `key` under `budget` (seconds; 0 = unlimited), or nil when unlimited.
    public func remaining(_ key: String, budget: Int) -> TimeInterval? {
        if budget <= 0 || unlimitedKeys.contains(key) { return nil }
        let cap = max(TimeInterval(budget), extended[key] ?? 0)
        return max(0, cap - spentTime(key))
    }

    public func isExhausted(_ key: String, budget: Int) -> Bool {
        guard let r = remaining(key, budget: budget) else { return false }
        return r <= Self.epsilon
    }

    /// "Keep thinking": another full budget period from now, or no limit when the setting is Unlimited.
    public mutating func extend(_ key: String, budget: Int) {
        if budget <= 0 { unlimitedKeys.insert(key); return }
        extended[key] = spentTime(key) + TimeInterval(budget)
    }

    public mutating func reset() { spent.removeAll(); extended.removeAll(); unlimitedKeys.removeAll() }
}

/// Whether live analysis may run given what the user can see: app active, a window visible, screen not locked or asleep.
public struct ActivityGate: Equatable, Sendable {
    public var appActive = true
    public var windowVisible = true
    public var screenAwake = true

    public init() {}

    public var shouldRun: Bool { appActive && windowVisible && screenAwake }

    /// Worth telling the user about: the window is on screen but the app is in the background.
    public var showsPausedNote: Bool { windowVisible && screenAwake && !appActive }
}

public extension EngineConfig {
    /// Per-position budget choices in seconds; 0 means unlimited.
    static let budgetChoices = [10, 30, 60, 300, 0]
    static let defaultBudgetSeconds = 30

    static func budgetLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "Unlimited" }
        return seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    /// Half the performance cores, at least 2.
    static func defaultThreads(performanceCores: Int) -> Int { max(2, performanceCores / 2) }

    /// Users who never changed threads still hold the old default (all performance cores): move them to the new default.
    static func migratedThreads(saved: Int, performanceCores: Int) -> Int {
        saved == max(1, performanceCores) ? defaultThreads(performanceCores: performanceCores) : saved
    }
}
