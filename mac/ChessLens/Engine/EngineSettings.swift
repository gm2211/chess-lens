import Foundation
import Observation

enum EnginePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case shallow, medium, deep, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    static let easy: [EnginePreset] = [.shallow, .medium, .deep]
    var depthCap: Int {
        switch self {
        case .shallow: 16
        case .medium, .custom: 24
        case .deep: 34
        }
    }
    var hash: Int {
        switch self {
        case .shallow: 128
        case .medium, .custom: 256
        case .deep: 512
        }
    }
}

struct EngineConfig: Codable, Equatable, Sendable {
    var preset: EnginePreset
    /// 0 means no limit.
    var depthCap: Int
    var lines: Int
    var threads: Int
    var hash: Int

    var depthText: String { depthCap == 0 ? "no depth limit" : "depth \(depthCap)" }
}

@Observable @MainActor
final class EngineSettings {
    static let hashSizes = [64, 128, 256, 512, 1024, 2048]
    static let depthRange = 8...60
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
            config = Self.values(for: .medium)
        }
    }

    static func values(for preset: EnginePreset) -> EngineConfig {
        clamped(EngineConfig(preset: preset, depthCap: preset.depthCap, lines: 3,
                             threads: UCIEngine.performanceCoreCount, hash: preset.hash))
    }

    private static func clamped(_ c: EngineConfig) -> EngineConfig {
        var c = c
        if c.depthCap != 0 { c.depthCap = min(max(c.depthCap, depthRange.lowerBound), depthRange.upperBound) }
        c.lines = min(max(c.lines, lineRange.lowerBound), lineRange.upperBound)
        c.threads = min(max(c.threads, threadRange.lowerBound), threadRange.upperBound)
        c.hash = hashSizes.min { abs($0 - c.hash) < abs($1 - c.hash) } ?? 256
        return c
    }

    func choose(_ preset: EnginePreset) {
        if preset == .custom {
            var c = config
            c.preset = .custom
            commit(c)
        } else {
            commit(Self.values(for: preset))
        }
    }

    /// Any hand edit flips the preset to Custom.
    func edit(_ change: (inout EngineConfig) -> Void) {
        var c = config
        change(&c)
        c.preset = .custom
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
