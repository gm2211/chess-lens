import Foundation
import Observation
import ChessCore

/// The guided review: walks the game's story beats on the main board, each told as a narrated scene the way a
/// video lesson explains a moment (see `GameLesson.SceneStep`): the stakes, "what would you play?", the game move,
/// "but wait" and the refutation, a rewind to the better move, then back to the game. Scene moves are a preview on
/// top of the board, never added to the game. Stepping through by hand, the scene stops at its question: the
/// player's try is shown as a preview and judged by the engine (see `BetterMove`). Played hands-free, it just holds
/// there. Owned by `AppModel.walkthrough`; see AppModel+Beats.
@Observable @MainActor
final class BeatWalkthrough {
    /// A beat with the game node it shows, its scene and, at an error, its question.
    struct Step: Equatable {
        var beat: GameLesson.Beat
        /// The position after the beat's move.
        var nodeID: Int
        var quiz: Quiz?
        /// Validated: its moves replay from `rootID`.
        var scene: [GameLesson.SceneStep]
        /// Where the scene starts: the question position at an error, else the beat's own position.
        var rootID: Int { quiz?.parentID ?? nodeID }
    }

    /// Everything needed to ask and judge "find a better move" at an error.
    struct Quiz: Equatable {
        var parentID: Int           // the position before the error: the question
        var side: Side
        var best: String            // UCI, the review's best move there
        var bestEval: Eval          // White's view, the review's eval of that position
        var bestLine: [String]      // the review's line from there
        var played: String          // UCI, the move played in the game
        var refutation: [String]    // the review's line after the move played
    }

    enum Phase: Equatable {
        /// The scene plays, or rests on `sceneIndex`.
        case scene
        /// Stopped at the scene's question, waiting for the player's move.
        case asking
        case judging(Move)
        case verdict(BetterMove.Verdict, tried: Move, reply: String?)
    }

    static let narrateKey = "beats.narrate"
    /// Scene moves slide slowly enough to follow, with a breath between them.
    static let moveAnimation = 0.8
    static let moveGap = 0.3
    static let stepGap = 0.3
    /// Hands-free, a question is held this long before the scene answers it.
    static let askHold = 1.5
    static let answerHold = 1.8

    let steps: [Step]
    private(set) var index = 0
    private(set) var phase: Phase = .scene
    /// Hands-free: every beat's scene in turn, questions held rather than asked.
    private(set) var isPlaying = false
    /// A scene is playing (by hand or hands-free).
    private(set) var isRunning = false
    private(set) var sceneIndex = 0
    /// The current scene has played to its end.
    private(set) var finished = false
    /// UCI moves shown on top of the board node (never added to the game).
    private(set) var sceneMoves: [String] = []
    /// The current scene step's arrows and circles are up (they appear once its moves are played).
    private(set) var marksShown = false
    /// Bumps each time marks change, so the board can animate its circles in.
    private(set) var epoch = 0
    var narrate = UserDefaults.standard.object(forKey: BeatWalkthrough.narrateKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(narrate, forKey: Self.narrateKey)
            if !narrate { narrator.stop() }
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var judgeTask: Task<Void, Never>?
    @ObservationIgnored private var travelTask: Task<Void, Never>?
    @ObservationIgnored private let narrator: any Narrator = VoiceNarrator()
    /// The node the walkthrough put on the board; any other navigation closes it (see `AppModel.currentID`).
    @ObservationIgnored private(set) var nodeID: Int
    /// The engine's answer to a wrong try (UCI), kept for its arrow.
    @ObservationIgnored private var replyUCI: String?

    init(steps: [Step], app: AppModel) {
        self.steps = steps; self.app = app
        nodeID = steps.first?.rootID ?? 0
    }

    var current: Step { steps[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < steps.count - 1 }
    var sceneStep: GameLesson.SceneStep? { current.scene.indices.contains(sceneIndex) ? current.scene[sceneIndex] : nil }
    /// Pieces slide at scene pace while a scene plays.
    var slowSlides: Bool { isRunning }

    /// The question is open: a move on the board is a try.
    var acceptsMove: Bool {
        guard let q = current.quiz, app?.currentID == q.parentID, travelTask == nil, sceneMoves.isEmpty else { return false }
        switch phase {
        case .asking: return true
        case .verdict(let v, _, _): return !v.isCorrect
        default: return false
        }
    }

    /// The answer must stay hidden: no engine lines while the question is open or the scene hasn't shown it yet.
    var hidesEngine: Bool {
        guard current.quiz != nil else { return false }
        switch phase {
        case .asking, .judging: return true
        case .verdict(let v, _, _): return !v.isCorrect
        case .scene:
            let reveal = current.scene.firstIndex { $0.rewind == .root } ?? current.scene.count
            return !finished && sceneIndex < reveal
        }
    }

    /// The player's try or the scene's moves, shown on the board on top of the node.
    var preview: LessonPlayer.Preview? {
        guard let app else { return nil }
        switch phase {
        case .judging(let m), .verdict(_, let m, _):
            guard let q = current.quiz, app.game.nodes.indices.contains(q.parentID) else { return nil }
            let pos = app.game.nodes[q.parentID].position
            guard let next = try? pos.applying(m) else { return nil }
            return LessonPlayer.Preview(pieces: PieceLayout.applying(m, before: pos, to: app.pieces(for: q.parentID)),
                                        position: next, lastMove: m)
        case .asking: return nil
        case .scene: break
        }
        guard !sceneMoves.isEmpty, app.game.nodes.indices.contains(nodeID) else { return nil }
        var pos = app.game.nodes[nodeID].position
        var pieces = app.pieces(for: nodeID)
        var last: Move?
        for u in sceneMoves {
            guard let m = pos.move(fromUCI: u) else { break }
            pieces = PieceLayout.applying(m, before: pos, to: pieces)
            pos = (try? pos.applying(m)) ?? pos; last = m
        }
        return LessonPlayer.Preview(pieces: pieces, position: pos, lastMove: last)
    }

    /// Arrows (kinds as the board draws them) and circles for what's on the board now.
    var marks: (arrows: [BoardArrow], circles: [Square]) {
        switch phase {
        case .asking, .judging: return ([], [])
        case .verdict(let v, _, _):
            guard !v.isCorrect, let u = replyUCI, let m = Move(uci: u) else { return ([], []) }
            return ([BoardArrow(from: m.from, to: m.to, kind: .threat, opacity: 0.85)], [])
        case .scene:
            guard marksShown, let s = sceneStep else { return ([], []) }
            return (s.arrows.map { BoardArrow(from: $0.from, to: $0.to, kind: .lesson, opacity: 0.82) }, s.circles)
        }
    }

    // MARK: Transport

    func start(at i: Int = 0) { show(i) }

    func next() { guard canGoForward else { return }; go(to: index + 1) }
    func previous() { guard canGoBack else { return }; go(to: index - 1) }
    func go(to i: Int) { guard steps.indices.contains(i) else { return }; show(i) }

    func togglePlay() { isPlaying || isRunning ? pause() : play() }

    /// Hands-free from here: the scene resumes (answering an open question), then every following beat plays.
    func play() {
        guard !steps.isEmpty else { return }
        isPlaying = true
        switch phase {
        case .asking, .judging, .verdict: continueScene()
        case .scene:
            if !finished { resume(at: sceneIndex) }
            else if canGoForward { go(to: index + 1) }
            else { go(to: 0) }
        }
    }

    func pause() {
        isPlaying = false
        isRunning = false
        task?.cancel(); task = nil
        narrator.stop()
    }

    func stop() {
        pause()
        judgeTask?.cancel(); judgeTask = nil
        travelTask?.cancel(); travelTask = nil
    }

    /// Plays the current beat's scene again from its first step.
    func replayScene() {
        judgeTask?.cancel(); judgeTask = nil
        resume(at: 0)
    }

    // MARK: Beats

    /// Puts beat `i` on the board at its scene's start and plays the scene.
    func show(_ i: Int) {
        task?.cancel(); task = nil
        judgeTask?.cancel(); judgeTask = nil
        narrator.stop()
        index = i
        resume(at: 0)
        app?.refreshEngine()
    }

    /// Restores the board as the scene has it before step `i` (what came before isn't replayed), then plays on.
    private func resume(at i: Int) {
        task?.cancel(); task = nil
        narrator.stop()
        replyUCI = nil
        phase = .scene
        finished = false
        var node = current.rootID, moves: [String] = []
        for s in current.scene.prefix(i) {
            if let r = s.rewind { node = r == .root ? current.rootID : current.nodeID; moves = [] }
            moves += s.moves
        }
        sceneIndex = i
        marksShown = false
        sceneMoves = moves
        travel(to: node)
        runScene(from: i)
    }

    /// Leaves the question and plays the rest of the scene ("Show me", "Skip the question", a right answer).
    func continueScene() {
        judgeTask?.cancel(); judgeTask = nil
        replyUCI = nil
        phase = .scene
        epoch += 1
        app?.refreshEngine()
        runScene(from: sceneIndex + 1)
    }

    /// "Try again": back to the question position.
    func clearAttempt() {
        guard current.quiz != nil else { return }
        if case .verdict(let v, _, _) = phase, !v.isCorrect { phase = .asking; replyUCI = nil }
    }

    /// Judges a try at the question (see `BetterMove`). The move is never added to the game.
    func submit(_ move: Move) {
        guard acceptsMove, let q = current.quiz, let app else { return }
        phase = .judging(move)
        replyUCI = nil
        let history = app.game.engineHistory(to: q.parentID)
        let before = app.game.nodes[q.parentID].position
        judgeTask?.cancel()
        judgeTask = Task { [weak self] in
            var eval: Eval?, reply: String?
            if move.uci != q.best && move.uci != q.played, let after = try? before.applying(move) {
                if after.legalMoves().isEmpty {
                    eval = after.isCheck ? .checkmate(winner: q.side) : .cp(0)
                } else if let line = try? await ToolEngine.shared.evaluate(rootFEN: history.rootFEN, moves: history.moves + [move.uci],
                                                                           whiteToMove: after.turn == .white) {
                    eval = line.eval; reply = line.pv.first
                }
            }
            guard let self, !Task.isCancelled, self.phase == .judging(move) else { return }
            if move.uci == q.played { reply = q.refutation.first }
            let replyText: String? = reply.flatMap { r in (try? before.applying(move)).flatMap { StoryBeats.moveLabel(r, from: $0) } }
            let v = BetterMove.judge(tried: move.uci, side: q.side, best: q.best, bestEval: q.bestEval, played: q.played,
                                     triedEval: eval, reply: replyText)
            self.replyUCI = v.isCorrect ? nil : reply
            self.phase = .verdict(v, tried: move, reply: replyText)
            self.epoch += 1
            self.app?.refreshEngine()
            // A right answer: a moment to enjoy it, then the scene goes on.
            guard v.isCorrect else { self.judgeTask = nil; return }
            try? await Task.sleep(for: .seconds(Self.answerHold))
            guard !Task.isCancelled, self.phase == .verdict(v, tried: move, reply: replyText) else { return }
            self.judgeTask = nil
            self.continueScene()
        }
    }

    // MARK: Scene playback

    /// Plays scene steps from `start`: rewind, speak the line while its moves slide in, show its marks, hold.
    /// By hand, a question on the question position stops the scene (see `Phase.asking`).
    private func runScene(from start: Int) {
        task?.cancel()
        let scene = current.scene, beat = index
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.travelTask?.value
            for i in min(start, scene.count)..<scene.count {
                guard !Task.isCancelled, self.index == beat else { return }
                let s = scene[i]
                self.sceneIndex = i
                self.marksShown = false
                if self.narrate { self.narrator.prepare(scene[i...].prefix(3).map(\.say)) }
                if let r = s.rewind { await self.rewind(r) }
                guard !Task.isCancelled else { return }
                async let spoken: Void = self.speak(s.say)
                await self.play(s.moves)
                guard !Task.isCancelled else { return }
                self.marksShown = true
                self.epoch += 1
                await spoken
                guard !Task.isCancelled else { return }
                if s.ask {
                    if !self.isPlaying, let q = self.current.quiz, self.sceneMoves.isEmpty, self.nodeID == q.parentID {
                        self.isRunning = false
                        self.task = nil
                        self.phase = .asking
                        self.app?.refreshEngine()
                        return
                    }
                    try? await Task.sleep(for: .seconds(Self.askHold))
                }
                try? await Task.sleep(for: .seconds(s.pause ?? Self.stepGap))
            }
            guard !Task.isCancelled else { return }
            self.isRunning = false
            self.finished = true
            self.task = nil
            self.app?.refreshEngine()
            guard self.isPlaying else { return }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled, self.isPlaying else { return }
            if self.canGoForward { self.go(to: self.index + 1) } else { self.isPlaying = false }
        }
    }

    /// Jumps back to the question position or the game's position, clearing the scene's moves (they slide back).
    private func rewind(_ r: GameLesson.SceneStep.Rewind) async {
        let target = r == .root ? current.rootID : current.nodeID
        let moved = !sceneMoves.isEmpty || app?.currentID != target
        sceneMoves = []
        if app?.currentID != target {
            travel(to: target, perHop: Self.moveAnimation + Self.moveGap)
            await travelTask?.value
        }
        if moved { try? await Task.sleep(for: .seconds(Self.moveAnimation)) }
    }

    /// Plays `moves` on top of the board one at a time, starting as the line starts being spoken.
    private func play(_ moves: [String]) async {
        guard !moves.isEmpty else { return }
        try? await Task.sleep(for: .seconds(0.35))
        for u in moves {
            guard !Task.isCancelled else { return }
            sceneMoves.append(u)
            try? await Task.sleep(for: .seconds(Self.moveAnimation + Self.moveGap))
        }
    }

    /// Reads `text` aloud, or waits as long as reading it takes (also when the voice fails at once).
    private func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        let started = ContinuousClock.now
        if narrate { await narrator.speak(text) }
        guard !Task.isCancelled else { return }
        let spoken = ContinuousClock.now - started
        if !narrate || spoken < .milliseconds(300) {
            let left = Duration.seconds(Self.readingTime(text)) - spoken
            if left > .zero { try? await Task.sleep(for: left) }
        }
    }

    /// Seconds to read a scene line silently: short lines go by quickly, at least 1.6 s.
    static func readingTime(_ text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return max(1.6, Double(words) / 3.2 + 0.5)
    }

    /// Goes to `target`, replaying the game moves in between so the pieces slide (see `PieceMotion.hops`).
    private func travel(to target: Int, perHop: Double = LessonPlayer.secondsPerHop) {
        travelTask?.cancel(); travelTask = nil
        guard let app else { nodeID = target; return }
        let hops = PieceMotion.hops(from: app.currentID, to: target) { app.game.nodes[$0].parent }
        guard let first = hops.first else { nodeID = target; return }
        nodeID = first
        app.goto(first)
        guard hops.count > 1 else { return }
        let rest = Array(hops.dropFirst())
        travelTask = Task { [weak self] in
            for n in rest {
                try? await Task.sleep(for: .seconds(perHop))
                guard !Task.isCancelled, let self, let app = self.app else { return }
                self.nodeID = n
                app.goto(n)
            }
            self?.travelTask = nil
        }
    }
}
