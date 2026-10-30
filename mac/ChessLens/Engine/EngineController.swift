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

    var isAvailable: Bool { engine != nil }

    let settings = EngineSettings()
    /// Called after a settings change so the owner can restart the current analysis.
    @ObservationIgnored var onSettingsApplied: (() -> Void)?

    private let engine: UCIEngine?
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = 0

    init(executableURL: URL? = UCIEngine.defaultExecutableURL) {
        let c = settings.config
        engine = executableURL.map { UCIEngine(executableURL: $0, threads: c.threads, hash: c.hash) }
        if engine == nil { status = .failed("The Stockfish engine is missing from this build.") }
        settings.onChange = { [weak self] old, new in self?.settingsChanged(old, new) }
    }

    private func settingsChanged(_ old: EngineConfig, _ new: EngineConfig) {
        if new.lines < old.lines { lines.removeAll { $0.rank > new.lines } }
        guard let engine else { return }
        Task { [weak self] in
            await engine.setOptions(threads: new.threads, hash: new.hash)
            self?.onSettingsApplied?()
        }
    }

    // MARK: Live analysis

    /// Starts (or restarts, after a short debounce) live analysis of `position`.
    func analyze(_ position: Position, debounce: Duration = .milliseconds(140)) {
        liveTask?.cancel()
        guard let engine else { return }
        liveGeneration += 1
        let gen = liveGeneration
        let fen = position.fen
        // A finished game has nothing to analyse.
        if position.legalMoves().isEmpty {
            lines = []; linesFEN = fen; depth = 0; nps = 0; searching = false
            liveTask = Task { await engine.stop() }
            return
        }
        searching = true
        if linesFEN != fen { lines = []; depth = 0 }
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self?.runLive(engine: engine, position: position, fen: fen, gen: gen)
        }
    }

    private func runLive(engine: UCIEngine, position: Position, fen: String, gen: Int) async {
        if status == .idle { status = .starting }
        let cfg = settings.config
        do {
            let stream = try await engine.search(fen: fen, limit: .infinite(depthCap: cfg.depthCap == 0 ? .max : cfg.depthCap), multiPV: cfg.lines)
            if gen != liveGeneration { return }
            status = .running
            linesFEN = fen
            for await event in stream {
                if Task.isCancelled || gen != liveGeneration { return }
                switch event {
                case .info(let info):
                    guard info.hasScore, !info.isBound, !info.pv.isEmpty,
                          let eval = info.eval(whiteToMove: position.turn == .white) else { continue }
                    let sans = position.sanLine(fromUCI: info.pv, maxPlies: 14)
                    guard !sans.isEmpty else { continue }
                    let line = EngineLine(rank: info.multipv, eval: eval, depth: info.depth, pv: info.pv,
                                          text: position.numberedLine(fromUCI: info.pv, maxPlies: 14), sanMoves: sans)
                    apply(line)
                    if info.multipv == 1 { depth = info.depth }
                    if let n = info.nps { nps = n }
                case .finished:
                    searching = false
                }
            }
            if gen == liveGeneration { searching = false }
        } catch {
            engineLog.error("live search failed: \(String(describing: error), privacy: .public)")
            if gen == liveGeneration {
                status = .failed(error.localizedDescription)
                searching = false
            }
        }
    }

    private func apply(_ line: EngineLine) {
        if let i = lines.firstIndex(where: { $0.rank == line.rank }) { lines[i] = line }
        else { lines.append(line); lines.sort { $0.rank < $1.rank } }
    }

    func stopLive() {
        liveTask?.cancel()
        liveGeneration += 1
        searching = false
        if let engine { liveTask = Task { await engine.stop() } }
    }

    func clearLines() { lines = []; linesFEN = nil; depth = 0; nps = 0 }

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

    func newGame() { if let engine { Task { await engine.newGame() } } }
}
