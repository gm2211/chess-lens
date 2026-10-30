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

enum MoveClass: String {
    case inaccuracy = "?!", mistake = "?", blunder = "??"

    static func from(loss: Double) -> MoveClass? {
        loss >= 20 ? .blunder : loss >= 10 ? .mistake : loss >= 5 ? .inaccuracy : nil
    }
    var word: String {
        switch self {
        case .blunder: "a blunder"
        case .mistake: "a mistake"
        case .inaccuracy: "an inaccuracy"
        }
    }
    var rank: Int { self == .blunder ? 3 : self == .mistake ? 2 : 1 }
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

    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel(); task = nil
        entries = [:]; path = []; running = false; done = 0; hasResults = false
    }

    func cancel() { task?.cancel() }

    /// Reviews `line` (node ids from the root). `onFinish` reports completion or cancellation.
    func start(game: Game, line: [Int], engine: EngineController, onFinish: @escaping @MainActor (Bool) -> Void) {
        guard !running, line.count > 1 else { return }
        reset()
        depth = selectedDepth
        path = line
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
                        let mover = game.nodes[prevID].position.turn
                        var loss = 0.0
                        if prev.best != mv.uci {
                            loss = max(0, winPercent(prev.eval, for: mover) - winPercent(entry.eval, for: mover))
                        }
                        entry.loss = loss
                        entry.cls = MoveClass.from(loss: loss)
                    }
                }
                self.entries[id] = entry
                self.done = i + 1
                if i >= 1 { self.hasResults = true }
            }
            guard let self else { return }
            self.running = false
            onFinish(finished && !Task.isCancelled)
        }
    }

    // MARK: Results

    func summary(game: Game) -> (white: SideSummary, black: SideSummary) {
        var w = SideSummary(), b = SideSummary()
        var wAcc = 0.0, bAcc = 0.0
        for id in path.dropFirst() where game.nodes.indices.contains(id) {
            guard let e = entries[id], let loss = e.loss, let parent = game.nodes[id].parent else { continue }
            let acc = max(0, min(100, 103.1668 * exp(-0.04354 * loss) - 3.1669))
            let isWhite = game.nodes[parent].position.turn == .white
            if isWhite { w.moves += 1; wAcc += acc } else { b.moves += 1; bAcc += acc }
            switch e.cls {
            case .inaccuracy?: if isWhite { w.inaccuracies += 1 } else { b.inaccuracies += 1 }
            case .mistake?: if isWhite { w.mistakes += 1 } else { b.mistakes += 1 }
            case .blunder?: if isWhite { w.blunders += 1 } else { b.blunders += 1 }
            case nil: break
            }
        }
        if w.moves > 0 { w.accuracy = wAcc / Double(w.moves) }
        if b.moves > 0 { b.accuracy = bAcc / Double(b.moves) }
        return (w, b)
    }

    /// Worst moves first.
    func criticalMoments(limit: Int = 8) -> [Int] {
        path.compactMap { id -> (Int, Double)? in
            guard let e = entries[id], e.cls != nil, let l = e.loss else { return nil }
            return (id, l)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map(\.0)
    }
}
