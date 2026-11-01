import Foundation
import Observation
import ChessCore

struct EngineLine: Identifiable, Equatable {
    var id: Int { rank }
    var rank: Int               // 1-based MultiPV index
    var eval: Eval              // White's point of view
    var depth: Int
    var pv: [String]            // UCI moves
    var text: String            // numbered SAN, e.g. "12. Nf3 Nc6 13. Bb5"
    var sanMoves: [String]
    var firstMove: String? { pv.first }
}

struct FixedResult {
    var eval: Eval
    var bestMove: String?
    var depth: Int
    var pv: [String] = []       // full principal variation (UCI)
}

@Observable @MainActor
final class EngineController {
    enum Status: Equatable { case idle, starting, running, failed(String) }

    private(set) var status: Status = .idle
    private(set) var lines: [EngineLine] = []
    private(set) var linesFEN: String?
    private(set) var depth = 0
    private(set) var nps = 0
    private(set) var searching = false
    /// Why live analysis is not running for the position on the board (nil while it searches).
    enum PauseReason: Equatable { case manual, cool(CoolDownReason) }
    private(set) var pauseReason: PauseReason?

    var isAvailable: Bool { engine != nil }

    let settings = EngineSettings()
    /// Called after a settings change so the owner can restart the current analysis.
    @ObservationIgnored var onSettingsApplied: (() -> Void)?

    private let engine: UCIEngine?
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = 0
    private var coolDown = CoolDown()
    private var pausedKeys: Set<String> = []       // positions the user stopped by hand (cache keys)
    private var currentKey: String?

    // Smooth publishing: lines change once per completed depth, throttled, never regress below a stronger cached result.
    private struct CachedEval {
        var lines: [EngineLine]
        var depth: Int
        var nodes: Int
        var nps: Int?
    }
    private struct Pending { var fen: String; var key: String; var lines: [EngineLine]; var depth: Int; var nodes: Int; var nps: Int? }
    private var cache: [String: CachedEval] = [:]
    private var cacheOrder: [String] = []          // least recently used first
    private let cacheLimit = 500
    private var pending: Pending?
    private var flushTask: Task<Void, Never>?
    private var scheduledGen = -1
    private var lastPublish = ContinuousClock.now
    private var searchStart = ContinuousClock.now
    private var shownKey: String?
    private var shownNodes = 0                     // strength of what `lines` currently shows
    private var shownDepth = 0
    private var shownLineCount = 0
    private let publishInterval: Duration = .milliseconds(125)
    private let minDepthToShow = 8
    private let minWaitToShow: Duration = .milliseconds(250)

    init(executableURL: URL? = UCIEngine.defaultExecutableURL) {
        let c = settings.config
        engine = executableURL.map { UCIEngine(executableURL: $0, threads: c.threads, hash: c.hash) }
        if engine == nil { status = .failed("The Stockfish engine is missing from this build.") }
        settings.onChange = { [weak self] old, new in self?.settingsChanged(old, new) }
        updateCoolDown()
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.heatChanged() }
            }
        }
    }

    // MARK: Pause / continue

    private func updateCoolDown() {
        let info = ProcessInfo.processInfo
        let level: ThermalLevel
        switch info.thermalState {
        case .nominal: level = .nominal
        case .fair: level = .fair
        case .serious: level = .serious
        case .critical: level = .critical
        @unknown default: level = .serious
        }
        coolDown.update(thermal: level, lowPower: info.isLowPowerModeEnabled, enabled: settings.config.pauseWhenHot)
    }

    private func heatChanged() {
        let before = coolDown.reason
        updateCoolDown()
        if coolDown.reason != before { onSettingsApplied?() }
    }

    /// Stops the search for the position on the board and freezes its lines until `resume()`.
    func pause() {
        guard let engine, let key = currentKey, searching else { return }
        flushPending(cfg: settings.config, force: true)
        pausedKeys.insert(key)
        liveTask?.cancel()
        liveGeneration += 1
        searching = false
        pauseReason = .manual
        liveTask = Task { await engine.stop() }
    }

    /// Continue button: lifts the manual pause on this position, or overrides the cool-down pause.
    func resume() {
        switch pauseReason {
        case .manual?: if let currentKey { pausedKeys.remove(currentKey) }
        case .cool?: coolDown.continueAnyway()
        case nil: return
        }
        onSettingsApplied?()
    }

    private func settingsChanged(_ old: EngineConfig, _ new: EngineConfig) {
        if new.lines < old.lines { lines.removeAll { $0.rank > new.lines } }
        if new.lines != old.lines { cache.removeAll(); cacheOrder.removeAll(); pausedKeys.removeAll() }
        if new.pauseWhenHot != old.pauseWhenHot { updateCoolDown() }
        guard let engine else { return }
        Task { [weak self] in
            await engine.setOptions(threads: new.threads, hash: new.hash)
            self?.onSettingsApplied?()
        }
    }

    // MARK: Live analysis

    /// Starts (or restarts, after a short debounce) live analysis of `position`.
    /// `history` is the root FEN and the moves leading to `position` (`Game.engineHistory`), so Stockfish sees repetitions.
    func analyze(_ position: Position, history: (rootFEN: String, moves: [String])? = nil, debounce: Duration = .milliseconds(140)) {
        liveTask?.cancel()
        guard let engine else { return }
        liveGeneration += 1
        let gen = liveGeneration
        let fen = position.fen
        // A finished game has nothing to analyse.
        if position.legalMoves().isEmpty { finish(fen: fen, engine: engine); return }
        flushTask?.cancel(); pending = nil
        let cfg = settings.config
        let key = Self.cacheKey(fen, history, cfg.lines)
        if shownKey != key || linesFEN != fen {
            if let hit = touchCache(key) {
                // Back at a known position: show the stored result straight away.
                lines = hit.lines; depth = hit.depth; linesFEN = fen; shownKey = key
                shownNodes = hit.nodes; shownDepth = hit.depth; shownLineCount = hit.lines.count
            } else {
                lines = []; depth = 0; shownKey = nil; shownNodes = 0; shownDepth = 0; shownLineCount = 0
            }
        }
        currentKey = key
        if let cool = coolDown.reason {
            pauseReason = .cool(cool)
        } else if pausedKeys.contains(key) {
            pauseReason = .manual
        } else {
            pauseReason = nil
        }
        if pauseReason != nil {
            searching = false
            liveTask = Task { await engine.stop() }
            return
        }
        searching = true
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self?.runLive(engine: engine, position: position, fen: fen, history: history, gen: gen)
        }
    }

    private func runLive(engine: UCIEngine, position: Position, fen: String, history: (rootFEN: String, moves: [String])?, gen: Int) async {
        let key = Self.cacheKey(fen, history, settings.config.lines)
        if status == .idle { status = .starting }
        let cfg = settings.config
        do {
            let stream = try await engine.search(fen: history?.rootFEN ?? fen, moves: history?.moves ?? [], limit: .infinite(depthCap: .max), multiPV: cfg.lines)
            if gen != liveGeneration { return }
            status = .running
            if linesFEN != fen { linesFEN = fen }
            searchStart = .now
            var acc = SnapshotAccumulator(expectedPVs: min(cfg.lines, position.legalMoves().count))
            for await event in stream {
                if Task.isCancelled || gen != liveGeneration { return }
                switch event {
                case .info(let info):
                    guard let snap = acc.accumulate(info) else { continue }
                    var out: [EngineLine] = []
                    for (i, pv) in snap.ranked.enumerated() {
                        guard let eval = pv.eval(whiteToMove: position.turn == .white) else { continue }
                        let sans = position.sanLine(fromUCI: pv.pv, maxPlies: 14)
                        guard !sans.isEmpty else { continue }
                        out.append(EngineLine(rank: i + 1, eval: eval, depth: pv.depth, pv: pv.pv,
                                              text: position.numberedLine(fromUCI: pv.pv, maxPlies: 14), sanMoves: sans))
                    }
                    guard !out.isEmpty else { continue }
                    pending = Pending(fen: fen, key: key, lines: out, depth: snap.depth, nodes: snap.nodes, nps: snap.nps)
                    schedulePublish(gen: gen, cfg: cfg)
                case .finished:
                    flushPending(cfg: cfg, force: true)
                    searching = false
                }
            }
            if gen == liveGeneration { flushPending(cfg: cfg, force: true); searching = false }
        } catch {
            engineLog.error("live search failed: \(String(describing: error), privacy: .public)")
            if gen == liveGeneration {
                status = .failed(error.localizedDescription)
                searching = false
            }
        }
    }

    /// The game is over at `position` (mate, stalemate, draw): no lines, nothing searched.
    func markGameOver(_ position: Position) {
        liveTask?.cancel()
        guard let engine else { return }
        liveGeneration += 1
        finish(fen: position.fen, engine: engine)
    }

    private func finish(fen: String, engine: UCIEngine) {
        flushTask?.cancel(); pending = nil
        pauseReason = nil; currentKey = nil
        lines = []; linesFEN = fen; depth = 0; nps = 0; searching = false; shownKey = nil; shownNodes = 0; shownDepth = 0; shownLineCount = 0
        liveTask = Task { await engine.stop() }
    }

    private static func cacheKey(_ fen: String, _ history: (rootFEN: String, moves: [String])?, _ lines: Int) -> String {
        "\(history?.rootFEN ?? fen)|\((history?.moves ?? []).joined(separator: " "))|\(lines)"
    }

    private func touchCache(_ key: String) -> CachedEval? {
        guard let hit = cache[key] else { return nil }
        if let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i) }
        cacheOrder.append(key)
        return hit
    }

    private func store(_ key: String, _ value: CachedEval) {
        cache[key] = value
        if let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i) }
        cacheOrder.append(key)
        while cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Publishes the newest completed snapshot at most every `publishInterval`; holds back shallow first results
    /// (depth < `minDepthToShow`) for up to `minWaitToShow` when nothing is shown yet.
    private func schedulePublish(gen: Int, cfg: EngineConfig) {
        let now = ContinuousClock.now
        var due = lastPublish + publishInterval
        if lines.isEmpty, let p = pending, p.depth < minDepthToShow { due = max(due, searchStart + minWaitToShow) }
        if due <= now { flushPending(cfg: cfg, force: false); return }
        if flushTask != nil, flushTask?.isCancelled == false, scheduledGen == gen { return }
        scheduledGen = gen
        flushTask = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            if Task.isCancelled { return }
            guard let self, gen == self.liveGeneration else { return }
            self.flushTask = nil
            self.flushPending(cfg: cfg, force: false)
        }
    }

    private func flushPending(cfg: EngineConfig, force: Bool) {
        flushTask?.cancel(); flushTask = nil
        guard let p = pending else { return }
        pending = nil
        // Never replace a stronger result (e.g. a cached deeper search) with a weaker one, unless the line count differs.
        let sameCount = shownLineCount == p.lines.count
        let stronger = p.nodes > 0 && shownNodes > 0 ? p.nodes >= shownNodes : p.depth >= shownDepth
        guard lines.isEmpty || !sameCount || stronger else { return }
        lines = p.lines; depth = p.depth; linesFEN = p.fen
        if let n = p.nps { nps = n }
        shownNodes = p.nodes; shownDepth = p.depth; shownLineCount = p.lines.count
        lastPublish = .now
        shownKey = p.key
        store(p.key, CachedEval(lines: p.lines, depth: p.depth, nodes: p.nodes, nps: p.nps))
    }

    func stopLive() {
        flushTask?.cancel(); pending = nil
        liveTask?.cancel()
        liveGeneration += 1
        searching = false
        pauseReason = nil
        if let engine { liveTask = Task { await engine.stop() } }
    }

    func clearLines() { flushTask?.cancel(); pending = nil; lines = []; linesFEN = nil; depth = 0; nps = 0; shownKey = nil; shownNodes = 0; shownDepth = 0; shownLineCount = 0 }

    // MARK: Fixed-depth (review)

    func analyzeFixed(_ position: Position, depth target: Int) async -> FixedResult? {
        guard let engine else { return nil }
        liveTask?.cancel()
        liveGeneration += 1
        searching = false
        do {
            let stream = try await engine.search(fen: position.fen, limit: .depth(target), multiPV: 1)
            status = .running
            var last: FixedResult?
            for await event in stream {
                if Task.isCancelled { return nil }
                switch event {
                case .info(let info):
                    if info.hasScore, !info.isBound, let e = info.eval(whiteToMove: position.turn == .white) {
                        last = FixedResult(eval: e, bestMove: info.pv.first ?? last?.bestMove, depth: info.depth,
                                           pv: info.pv.isEmpty ? (last?.pv ?? []) : info.pv)
                    }
                case .finished(let best, let completed):
                    guard completed else { return nil }
                    if var l = last { if let best { l.bestMove = best; if l.pv.first != best { l.pv = [best] } }; return l }
                    return nil
                }
            }
            return nil
        } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    func cancelAll() async {
        liveTask?.cancel()
        liveGeneration += 1
        searching = false
        await engine?.stop()
    }

    func shutdown() async { await engine?.shutdown() }

    func newGame() { cache.removeAll(); cacheOrder.removeAll(); pausedKeys.removeAll(); if let engine { Task { await engine.newGame() } } }
}
