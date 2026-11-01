import Foundation
import Observation
import ChessCore

@Observable @MainActor
final class EngineSettings {
    static let hashSizes = [64, 128, 256, 512, 1024, 2048]
    static let lineRange = 1...5
    static var threadRange: ClosedRange<Int> { 1...max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private static let key = "engineSettings"

    private(set) var config: EngineConfig
    /// Called with (old, new) after a change was stored.
    @ObservationIgnored var onChange: ((EngineConfig, EngineConfig) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(EngineConfig.self, from: data) {
            config = Self.clamped(saved)
        } else {
            config = Self.clamped(EngineConfig(threads: UCIEngine.performanceCoreCount))
        }
    }

    private static func clamped(_ c: EngineConfig) -> EngineConfig {
        var c = c
        c.lines = min(max(c.lines, lineRange.lowerBound), lineRange.upperBound)
        c.threads = min(max(c.threads, threadRange.lowerBound), threadRange.upperBound)
        c.hash = hashSizes.min { abs($0 - c.hash) < abs($1 - c.hash) } ?? EngineConfig.defaultHash
        return c
    }

    func edit(_ change: (inout EngineConfig) -> Void) {
        var c = config
        change(&c)
        commit(c)
    }

    private func commit(_ new: EngineConfig) {
        let new = Self.clamped(new)
        guard new != config else { return }
        let old = config
        config = new
        if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: Self.key) }
        onChange?(old, new)
    }
}
