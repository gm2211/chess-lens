import Foundation
import AVFoundation
import Observation
import ChessCore

/// Plays a concept's story on the main board like a narrated video: each step goes to its game position, circles
/// and points at what the narration talks about, acts out its hypothetical `line` on top (a preview, never added to
/// the game) and moves on when the narration ends. Owned by `AppModel.lessonPlayer`; see AppModel+Lesson.
@Observable @MainActor
final class LessonPlayer {
    struct Step: Equatable {
        var step: GameLesson.StoryStep
        var nodeID: Int
        /// The concept this step belongs to, when the player runs a mixed playlist (the full review).
        var concept: String?
    }

    /// What the board shows instead of the current node while a step's line is being acted out.
    struct Preview: Equatable {
        var pieces: [PieceInstance]
        var position: Position
        var lastMove: Move?
    }

    static let narrateKey = "lesson.narrate"
    static let secondsPerLineMove = 0.6
    static let lineMoveAnimation = 0.42

    let title: String
    let steps: [Step]
    /// A playlist across all concepts ("Full review"): the bar shows each step's concept.
    let isFullReview: Bool
    private(set) var index = 0
    private(set) var isPlaying = false
    /// How many moves of the current step's line are on the board (0 = the game position itself).
    private(set) var linePly = 0
    /// Bumps each time a step (re)starts, so the board can animate its circles in.
    private(set) var stepEpoch = 0
    /// The last step has played out.
    private(set) var finished = false
    var narrate = UserDefaults.standard.object(forKey: LessonPlayer.narrateKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(narrate, forKey: Self.narrateKey)
            if !narrate { narrator.stop() }
            if isPlaying { restartStep() }
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Replays the game moves between two steps, one slide at a time (see `show`).
    @ObservationIgnored private var travelTask: Task<Void, Never>?
    static let secondsPerHop = 0.35
    @ObservationIgnored private let narrator = Narrator()
    /// The node the player put on the board; any other navigation closes the player (see `AppModel.currentID`).
    @ObservationIgnored private(set) var nodeID: Int

    init(title: String, steps: [Step], app: AppModel, isFullReview: Bool = false) {
        self.title = title; self.steps = steps; self.app = app; self.isFullReview = isFullReview
        nodeID = steps.first?.nodeID ?? 0
    }

    var current: Step { steps[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < steps.count - 1 }

    /// The current step's line in SAN, from its game position.
    var lineSAN: [String] {
        guard let app, app.game.nodes.indices.contains(current.nodeID) else { return [] }
        return app.game.nodes[current.nodeID].position.sanLine(fromUCI: current.step.line)
    }

    var preview: Preview? {
        guard linePly > 0, let app, app.game.nodes.indices.contains(current.nodeID) else { return nil }
        var pos = app.game.nodes[current.nodeID].position
        var pieces = app.pieces(for: current.nodeID)
        var last: Move?
        for u in current.step.line.prefix(linePly) {
            guard let m = pos.move(fromUCI: u), let next = try? pos.applying(m) else { break }
            pieces = PieceLayout.applying(m, before: pos, to: pieces)
            pos = next; last = m
        }
        return Preview(pieces: pieces, position: pos, lastMove: last)
    }

    // MARK: Transport

    func start() {
        show(0)
        play()
    }

    func play() {
        guard !steps.isEmpty else { return }
        if finished { show(0) }                       // played to the end: start again from the top
        isPlaying = true
        restartStep()
    }

    func pause() {
        isPlaying = false
        task?.cancel(); task = nil
        narrator.stop()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func next() { guard canGoForward else { return }; go(to: index + 1) }
    func previous() {
        // Mid-step (line shown or narration under way) goes back to the step's start first, like a video player.
        if linePly > 0 || !canGoBack { go(to: index) } else { go(to: index - 1) }
    }

    func go(to i: Int) {
        guard steps.indices.contains(i) else { return }
        show(i)
        if isPlaying { restartStep() } else { task?.cancel(); task = nil; narrator.stop() }
    }

    /// Stops narration and timers. The board falls back to the current node by itself once the player is gone.
    func stop() {
        isPlaying = false
        travelTask?.cancel(); travelTask = nil
        task?.cancel(); task = nil
        narrator.stop()
    }

    // MARK: Steps

    /// Puts step `i` on the board (its game position, no line moves yet).
    func show(_ i: Int) {
        task?.cancel(); task = nil
        narrator.stop()
        index = i
        finished = false
        linePly = 0
        stepEpoch += 1
        travel(to: steps[i].nodeID)
    }

    /// Goes to `target`, replaying the game moves in between one by one so the pieces slide (a long way: jumps
    /// most of it, animating the last few). Unrelated positions just change.
    private func travel(to target: Int) {
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
                try? await Task.sleep(for: .seconds(Self.secondsPerHop))
                guard !Task.isCancelled, let self, let app = self.app else { return }
                self.nodeID = n
                app.goto(n)
            }
        }
    }

    /// Sets how many line moves are shown (for previews and tests).
    func setLinePly(_ n: Int) { linePly = max(0, min(n, current.step.line.count)) }

    private func restartStep() {
        task?.cancel()
        narrator.stop()
        if linePly > 0 { linePly = 0; stepEpoch += 1 }
        let step = current.step
        let narrate = narrate
        task = Task { [weak self] in
            guard let self else { return }
            await self.travelTask?.value
            guard !Task.isCancelled else { return }
            async let spoken: Void = self.narration(step.say, narrate: narrate)
            await self.actOutLine(step.line.count)
            await spoken
            try? await Task.sleep(for: .seconds(step.pause ?? 0.7))
            guard !Task.isCancelled else { return }
            self.task = nil
            if self.canGoForward { self.go(to: self.index + 1) } else { self.isPlaying = false; self.finished = true }
        }
    }

    private func narration(_ text: String, narrate: Bool) async {
        if narrate {
            await narrator.speak(text)
        } else {
            try? await Task.sleep(for: .seconds(Self.readingTime(text)))
        }
    }

    /// Plays the line one move at a time, after a beat so the circles and arrows register first.
    private func actOutLine(_ count: Int) async {
        guard count > 0 else { return }
        try? await Task.sleep(for: .seconds(1.1))
        for n in 1...count {
            guard !Task.isCancelled else { return }
            linePly = n
            try? await Task.sleep(for: .seconds(Self.secondsPerLineMove))
        }
    }

    /// Seconds to read `text` silently: about 180 words a minute, at least 2.5 s.
    static func readingTime(_ text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return max(2.5, Double(words) / 3.0 + 0.6)
    }
}

/// Speaks with the system voice and returns when the utterance ends (or is stopped / the task cancelled).
@MainActor
private final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var waiting: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let u = AVSpeechUtterance(string: Self.spoken(text))
        u.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.postUtteranceDelay = 0.1
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                waiting = c
                synth.speak(u)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        let c = waiting; waiting = nil
        c?.resume()
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.resume() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.resume() }
    }

    /// Notation read the way a coach would say it: "6...Nf6" becomes "6, knight f6".
    static func spoken(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{2026}", with: "...")
        s = s.replacingOccurrences(of: "O-O-O", with: "castles long").replacingOccurrences(of: "O-O", with: "castles")
        let pieces: [Character: String] = ["K": "king", "Q": "queen", "R": "rook", "B": "bishop", "N": "knight"]
        let rx = try! NSRegularExpression(pattern: #"\b(\d{1,3})(\.\.\.|\.)\s?([KQRBN])?([a-h]?[1-8]?)(x)?([a-h][1-8])(=[QRBN])?([+#])?"#)
        let ns = s as NSString
        var out = "", last = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            var words = [g(1)! + ","]
            if let p = g(3)?.first { words.append(pieces[p] ?? "") }
            if let d = g(4), !d.isEmpty { words.append(d) }
            if g(5) != nil { words.append("takes") }
            words.append(g(6)!)
            if let promo = g(7)?.last { words.append("promotes to " + (pieces[promo] ?? "queen")) }
            if let c = g(8) { words.append(c == "#" ? "mate" : "check") }
            out += words.joined(separator: " ")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
