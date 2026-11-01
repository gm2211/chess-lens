import Foundation
import Observation
import ChessCore

enum ReviewDepth: Int, CaseIterable, Identifiable {
    case fast = 12, standard = 16, deep = 20
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .fast: "Fast (depth 12)"
        case .standard: "Standard (depth 16)"
        case .deep: "Deep (depth 20)"
        }
    }
}

enum MoveClass: String, CaseIterable {
    case brilliant = "!!", great = "!", inaccuracy = "?!", mistake = "?", blunder = "??"

    static func from(loss: Double) -> MoveClass? {
        loss >= 20 ? .blunder : loss >= 10 ? .mistake : loss >= 5 ? .inaccuracy : nil
    }
    var word: String {
        switch self {
        case .brilliant: "a brilliant move"
        case .great: "a great move"
        case .blunder: "a blunder"
        case .mistake: "a mistake"
        case .inaccuracy: "an inaccuracy"
        }
    }
    /// For prompts: "blunder", "great move".
    var name: String {
        switch self {
        case .brilliant: "brilliant move"
        case .great: "great move"
        case .blunder: "blunder"
        case .mistake: "mistake"
        case .inaccuracy: "inaccuracy"
        }
    }
    func plural(_ n: Int) -> String {
        switch self {
        case .brilliant: n == 1 ? "brilliant move" : "brilliant moves"
        case .great: n == 1 ? "great move" : "great moves"
        case .blunder: n == 1 ? "blunder" : "blunders"
        case .mistake: n == 1 ? "mistake" : "mistakes"
        case .inaccuracy: n == 1 ? "inaccuracy" : "inaccuracies"
        }
    }
    var isError: Bool { severity > 0 }
    /// 0 for the positive classes, 1...3 for errors.
    var severity: Int {
        switch self {
        case .blunder: 3
        case .mistake: 2
        case .inaccuracy: 1
        case .great, .brilliant: 0
        }
    }
    var rank: Int { severity }
}

struct ReviewEntry: Equatable {
    var eval: Eval
    var best: String?          // engine's best move from this position (UCI)
    var depth: Int
    var pv: [String] = []      // engine's principal variation from this position (UCI)
    var loss: Double?          // win-probability points lost by the move that led here
    var cls: MoveClass?
}

struct SideSummary {
    var moves = 0
    var accuracy: Double?
    var inaccuracies = 0
    var mistakes = 0
    var blunders = 0
    var great = 0
    var brilliant = 0

    func count(_ c: MoveClass) -> Int {
        switch c {
        case .brilliant: brilliant
        case .great: great
        case .inaccuracy: inaccuracies
        case .mistake: mistakes
        case .blunder: blunders
        }
    }
}

/// Win probability (0...100) from the viewpoint of `color`.
func winPercent(_ eval: Eval, for color: Side) -> Double {
    let w = eval.whiteWinPercent
    return color == .white ? w : 100 - w
}

@Observable @MainActor
final class ReviewModel {
    private(set) var entries: [Int: ReviewEntry] = [:]
    private(set) var path: [Int] = []           // node ids in review order (root first)
    private(set) var depth: ReviewDepth = .standard
    private(set) var running = false
    private(set) var done = 0
    private(set) var hasResults = false
    var selectedDepth: ReviewDepth = .standard
    /// Critical moments whose full note (lines and AI lesson) the user opened in the move list; the rest show one line.
    var expandedMoments: Set<Int> = []

    let commentary = AICommentary()
    let lesson = AISummary()

    /// Side to move at the start of the reviewed line.
    private var rootTurn: Side = .white
    private var task: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?

    func reset() {
        task?.cancel(); task = nil
        autoTask?.cancel(); autoTask = nil
        commentary.reset()
        lesson.reset()
        entries = [:]; path = []; running = false; done = 0; hasResults = false
        expandedMoments = []
    }

    func cancel() { task?.cancel() }

    /// Reviews `line` (node ids from the root). `onFinish` reports completion or cancellation.
    /// A finished review also starts the AI lesson and the top moments' explanations when a provider is ready.
    func start(game: Game, line: [Int], engine: EngineController, onFinish: @escaping @MainActor (Bool) -> Void) {
        guard !running, line.count > 1 else { return }
        reset()
        depth = selectedDepth
        path = line
        rootTurn = game.nodes[line[0]].position.turn
        running = true
        let depthValue = depth.rawValue
        task = Task { [weak self] in
            await engine.cancelAll()
            var finished = true
            for (i, id) in line.enumerated() {
                if Task.isCancelled { finished = false; break }
                let pos = game.nodes[id].position
                var entry: ReviewEntry
                if pos.legalMoves().isEmpty {
                    let eval: Eval = pos.isCheck ? .checkmate(winner: pos.turn.opposite) : .cp(0)
                    entry = ReviewEntry(eval: eval, best: nil, depth: 0)
                } else if let r = await engine.analyzeFixed(pos, depth: depthValue) {
                    entry = ReviewEntry(eval: r.eval, best: r.bestMove, depth: r.depth, pv: r.pv)
                } else {
                    finished = false
                    break
                }
                guard let self else { return }
                if i > 0 {
                    let prevID = line[i - 1]
                    if let prev = self.entries[prevID], let mv = game.nodes[id].move {
                        let before = game.nodes[prevID].position
                        let mover = before.turn
                        var loss = 0.0
                        if prev.best != mv.uci {
                            loss = max(0, winPercent(prev.eval, for: mover) - winPercent(entry.eval, for: mover))
                        }
                        entry.loss = loss
                        entry.cls = MoveClass.from(loss: loss) ?? Self.positiveClass(before: before, move: mv, entry: entry, loss: loss)
                    }
                }
                self.entries[id] = entry
                self.done = i + 1
                if i >= 1 { self.hasResults = true }
            }
            guard let self else { return }
            self.running = false
            let ok = finished && !Task.isCancelled
            onFinish(ok)
            if ok { self.startAI(game: game) }
        }
    }

    /// "!!" / "!": an engine-approved sacrifice (the move costs material along the engine's line, yet loses
    /// under 2 win-% points and leaves the mover at least close to equal). "!!" when it gives up 3+ pawns' worth.
    /// The review searches one line only, so "only moves" (second-best much worse) aren't detected.
    private static func positiveClass(before: Position, move: Move, entry: ReviewEntry, loss: Double) -> MoveClass? {
        guard loss < 2, winPercent(entry.eval, for: before.turn) >= 40 else { return nil }
        let sac = before.sacrifice(played: move, reply: entry.pv)
        return sac >= 3 ? .brilliant : sac >= 2 ? .great : nil
    }

    // MARK: AI

    private func startAI(game: Game) {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            let hub = AIHub.shared
            if !hub.isReady { await hub.refresh(hub.selected) }
            guard let self, !Task.isCancelled else { return }
            // Not set up: the lesson card shows the hint; no work is started.
            guard hub.isReady else { self.lesson.markNeedsSetup(); return }
            let lessonTask = self.lesson.generate(game: game, review: self)
            // The on-device model runs one request at a time well; elsewhere the lesson and moments run side by side.
            if hub.selected == .apple { await lessonTask?.value }
            guard !Task.isCancelled else { return }
            self.commentary.explainAll(self.autoMoments(), game: game, review: self)
        }
    }

    /// The AI provider or model changed. Whatever AI work is hung, failed or was waiting on a sign-in starts over with
    /// the new one; finished work stays. The engine review is untouched.
    func providerChanged(game: Game) {
        guard hasResults, !running else { return }
        let neverStarted = lesson.state == .needsSignIn && commentary.states.isEmpty
        lesson.providerChanged(game: game, review: self)
        if neverStarted {
            // The review finished with no provider ready, so the moments' notes were never started either.
            commentary.explainAll(autoMoments(), game: game, review: self)
        } else {
            commentary.providerChanged(game: game, review: self, automatic: autoMoments())
        }
    }

    /// The moments explained automatically: the six most important, in game order.
    func autoMoments(limit: Int = 6) -> [Int] {
        let picks = momentPicks()
        let keep = Set(picks.sorted { $0.score > $1.score }.prefix(limit).map(\.index))
        return picks.filter { keep.contains($0.index) }.map { path[$0.index] }
    }

    // MARK: Results

    func summary(game: Game) -> (white: SideSummary, black: SideSummary) {
        var w = SideSummary(), b = SideSummary()
        var wAcc = 0.0, bAcc = 0.0
        for id in path.dropFirst() where game.nodes.indices.contains(id) {
            guard let e = entries[id], let loss = e.loss, let parent = game.nodes[id].parent else { continue }
            let acc = PhaseReport.accuracy(loss: loss)
            let isWhite = game.nodes[parent].position.turn == .white
            if isWhite { w.moves += 1; wAcc += acc } else { b.moves += 1; bAcc += acc }
            func bump(_ s: inout SideSummary) {
                switch e.cls {
                case .inaccuracy?: s.inaccuracies += 1
                case .mistake?: s.mistakes += 1
                case .blunder?: s.blunders += 1
                case .great?: s.great += 1
                case .brilliant?: s.brilliant += 1
                case nil: break
                }
            }
            if isWhite { bump(&w) } else { bump(&b) }
        }
        if w.moves > 0 { w.accuracy = wAcc / Double(w.moves) }
        if b.moves > 0 { b.accuracy = bAcc / Double(b.moves) }
        return (w, b)
    }

    /// Phase of every reviewed position, by node id (see `GamePhases`). A move's phase is its parent's.
    func phases(game: Game) -> [Int: GamePhase] {
        let ids = path.filter { game.nodes.indices.contains($0) }
        let ph = GamePhases.classify(ids.map { game.nodes[$0].position }, plies: ids.map { game.nodes[$0].ply })
        return Dictionary(zip(ids, ph), uniquingKeysWith: { a, _ in a })
    }

    func phaseSummary(game: Game) -> [Side: [GamePhase: PhaseStat]] {
        let ph = phases(game: game)
        var moves: [ScoredMove] = []
        for id in path.dropFirst() where game.nodes.indices.contains(id) {
            guard let e = entries[id], let loss = e.loss, let parent = game.nodes[id].parent, let p = ph[parent] else { continue }
            moves.append(ScoredMove(side: game.nodes[parent].position.turn, phase: p, loss: loss, severity: e.cls?.severity ?? 0))
        }
        return PhaseReport.compute(moves)
    }

    /// Engine-picked moments (errors, strong moves, turning points) for both sides, in game order.
    /// A pick's `index` is its position in `path`.
    func momentPicks(limit: Int = 8) -> [PickedMoment] {
        var plies: [PlyReview] = []
        for i in path.indices.dropFirst() {
            guard let e = entries[path[i]], let prev = entries[path[i - 1]], let loss = e.loss else { continue }
            let mover: Side = i % 2 == 1 ? rootTurn : rootTurn.opposite
            plies.append(PlyReview(index: i, mover: mover, evalBefore: prev.eval, evalAfter: e.eval, loss: loss,
                                   severity: e.cls?.severity ?? 0,
                                   positive: e.cls == .brilliant ? 2 : e.cls == .great ? 1 : 0))
        }
        return MomentPicker.pick(plies, limit: limit)
    }

    /// Node ids of the critical moments, in game order.
    func criticalMoments(limit: Int = 8) -> [Int] {
        momentPicks(limit: limit).map { path[$0.index] }
    }
}
