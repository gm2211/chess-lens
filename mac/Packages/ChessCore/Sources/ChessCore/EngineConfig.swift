import Foundation

/// The user-facing engine settings. Old saves (with `preset` / `depthCap`) still decode; those fields are dropped.
public struct EngineConfig: Codable, Equatable, Sendable {
    public var lines: Int
    public var threads: Int
    public var hash: Int
    /// Pause live analysis when the Mac is hot or in Low Power Mode.
    public var pauseWhenHot: Bool
    /// Seconds each position is analysed before the engine stops by itself; 0 means unlimited.
    public var budgetSeconds: Int

    public static let defaultLines = 3
    public static let defaultHash = 256

    public init(lines: Int = defaultLines, threads: Int, hash: Int = defaultHash, pauseWhenHot: Bool = true, budgetSeconds: Int = EngineConfig.defaultBudgetSeconds) {
        self.lines = lines; self.threads = threads; self.hash = hash; self.pauseWhenHot = pauseWhenHot; self.budgetSeconds = budgetSeconds
    }

    private enum CodingKeys: String, CodingKey { case lines, threads, hash, pauseWhenHot, budgetSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? Self.defaultLines
        threads = try c.decode(Int.self, forKey: .threads)
        hash = try c.decodeIfPresent(Int.self, forKey: .hash) ?? Self.defaultHash
        pauseWhenHot = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenHot) ?? true
        budgetSeconds = try c.decodeIfPresent(Int.self, forKey: .budgetSeconds) ?? Self.defaultBudgetSeconds
    }
}

public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum CoolDownReason: Equatable, Sendable {
    case hot, lowPower
    public var message: String { self == .hot ? "Paused \u{2014} Mac is hot" : "Paused \u{2014} Low Power Mode" }
}

/// Decides when live analysis pauses itself. Pause when thermal state is serious or worse, or Low Power Mode is on
/// (and the setting is enabled); resume when thermal is fair or better and Low Power Mode is off.
/// "Continue" overrides the pause until the condition clears, so the next heat episode pauses again.
public struct CoolDown: Equatable, Sendable {
    public private(set) var latched: CoolDownReason?
    public private(set) var overridden = false

    public init() {}

    /// The reason analysis is paused right now, or nil when it may run.
    public var reason: CoolDownReason? { overridden ? nil : latched }

    public mutating func update(thermal: ThermalLevel, lowPower: Bool, enabled: Bool) {
        guard enabled else { latched = nil; overridden = false; return }
        if thermal >= .serious { latched = .hot }
        else if lowPower { latched = .lowPower }
        else { latched = nil; overridden = false }
    }

    public mutating func continueAnyway() { if latched != nil { overridden = true } }
}
