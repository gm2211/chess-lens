import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers
import ChessCore

enum SampleGames {
    static let opera = """
    [Event "Opera Game"]
    [Site "Paris FRA"]
    [Date "1858.??.??"]
    [Round "?"]
    [White "Paul Morphy"]
    [Black "Duke of Brunswick and Count Isouard"]
    [Result "1-0"]

    1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7
    8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7
    14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0
    """

    static var operaGame: Game { PGN.parse(opera)[0].game }
}

@Observable @MainActor
final class AppModel {
    // MARK: Game state
    private(set) var game: Game
    private(set) var currentID = 0 {
        didSet {
            if lessonFocus?.nodeID != currentID { lessonFocus = nil }   // moving away ends the illustration
            followLine()
            if let p = lessonPlayer, p.nodeID != currentID { lessonPlayer = nil }   // and the lesson being played
        }
    }
    /// The end of the line the move list shows (root → `lineTip`); `currentID` is always on it. It changes
    /// only when the user switches lines, so the move list can read it without rebuilding on every move.
    private(set) var lineTip = 0
    private(set) var epoch = 0 {                     // bumps when a different game is loaded
        didSet { lessonFocus = nil; lessonPlayer = nil }
    }
    /// A concept's story being played on the board (see AppModel+Lesson).
    var lessonPlayer: LessonPlayer? {
        didSet { if oldValue !== lessonPlayer { oldValue?.stop() } }
    }
    /// A summary example being illustrated on the board: its caption under the board and its arrows/squares on it.
    private(set) var lessonFocus: LessonFocus?
    var flipped = false
    /// Show the source's own comments, variations, glyphs and evals in the move list (not the app's review marks).
    var showSourceAnalysis = UserDefaults.standard.object(forKey: "showSourceAnalysis") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSourceAnalysis, forKey: "showSourceAnalysis") }
    }

    // MARK: UI state
    var showInspector = true
    var engineEnabled = true { didSet { if engineEnabled != oldValue { refreshEngine() } } }
    var showImport = false
    var showFileImporter = false
    var isDropTargeted = false
    var pendingImport: PendingImport?                // a drop waiting for confirmation
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    private(set) var toastText: String?
    var playSession: PlaySession?                    // "Continue against engine", see AppModel+Play
    var showPlaySetup = false

    let engine = EngineController()
    let review = ReviewModel()
    let importer = ImportModel()
    let ask = AskAI()                            // "Ask AI", see AppModel+Ask

    private var layoutCache: [Int: [PieceInstance]] = [:]
    private var toastTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        if let saved = Self.restore() {
            game = saved.game
            currentID = saved.node
            flipped = saved.flipped
            lineTip = game.lineTip(afterGoto: saved.node, currentTip: saved.tip ?? -1)
        } else {
            game = SampleGames.operaGame
            lineTip = game.mainline().last ?? 0
        }
        layoutCache = [:]
        engine.onSettingsApplied = { [weak self] in self?.refreshEngine() }
        refreshEngine()
    }

    // MARK: Derived

    var node: GameNode { game.nodes[currentID] }
    var position: Position { node.position }
    var lastMove: Move? { node.move }
    var canGoBack: Bool { node.parent != nil }
    var canGoForward: Bool { !node.children.isEmpty }
    /// The line the move list shows, root first.
    var displayLine: [Int] { game.displayLine(tip: lineTip) }
    /// Whether the shown line leaves the game's main line (the move list then offers "Back to game line").
    var isOffMainline: Bool { !game.isOnMainline(lineTip) }

    var title: String { PGN.title(of: game) }
    var subtitle: String {
        var parts: [String] = []
        if let e = PGN.meaningful(game.header("Event")), e != title { parts.append(e) }
        if let s = PGN.meaningful(game.header("Site")) { parts.append(s) }
        if let d = game.header("Date"), let y = d.split(separator: ".").first, y.allSatisfy(\.isNumber) { parts.append(String(y)) }
        if parts.isEmpty, game.nodes.count == 1 { return "Position" }
        return parts.joined(separator: " · ")
    }

    func pieces(for id: Int) -> [PieceInstance] {
        if let c = layoutCache[id] { return c }
        let n = game.nodes[id]
        let result: [PieceInstance]
        if let parent = n.parent, let move = n.move {
            result = PieceLayout.applying(move, before: game.nodes[parent].position, to: pieces(for: parent))
        } else {
            result = PieceLayout.initial(n.position)
        }
        layoutCache[id] = result
        return result
    }

    /// Eval to show on the bar: live engine line first, then the review result.
    var barEval: Eval? {
        if let outcome = terminalEval { return outcome }
        if engineEnabled, engine.linesFEN == position.fen, let l = engine.lines.first, l.depth >= barMinDepth { return l.eval }
        return review.entries[currentID]?.eval
    }

    /// Shallow search results swing wildly; the bar ignores them (EvalBar holds the previous value meanwhile).
    private var barMinDepth: Int {
        let cap = engine.settings.config.depthCap
        return cap == 0 ? 12 : min(12, cap)
    }

    var terminalEval: Eval? {
        switch game.gameEnd(at: currentID) {
        case .checkmate(let w)?: return .checkmate(winner: w)
        case _?: return .cp(0)
        case nil: return nil
        }
    }

    // MARK: Navigation

    func goto(_ id: Int) {
        guard game.nodes.indices.contains(id), id != currentID else { return }
        currentID = id
        didMove()
    }

    func back() { if let p = node.parent { goto(p) } }
    /// Next move along the shown line (not necessarily the main continuation).
    func forward() {
        if let c = game.nextOnLine(from: currentID, tip: lineTip) ?? node.children.first { goto(c) }
    }
    func first() { goto(0) }
    func last() {
        if currentID != lineTip, game.isOnLine(currentID, tip: lineTip) { goto(lineTip) }
        else { goto(game.mainline(from: currentID).last ?? currentID) }
    }

    /// Switches to the previous/next alternative at the current move's fork (⌥↑ / ⌥↓).
    func cycleBranch(_ offset: Int) {
        if let s = game.sibling(of: currentID, offset: offset) { goto(s) }
    }

    /// Leaves a side line: back to where the shown line left the main line, with the main line shown again.
    func backToGameLine() {
        let target = game.lastMainlineNode(on: displayLine)
        setLineTip(game.mainline().last ?? 0)
        goto(target)
    }

    /// Keeps `currentID` on the shown line: moving off it shows the main continuation from the new node.
    private func followLine() {
        setLineTip(game.lineTip(afterGoto: currentID, currentTip: lineTip))
    }

    private func setLineTip(_ id: Int) { if lineTip != id { lineTip = id } }

    func toggleFlip() { flipped.toggle(); persist() }

    /// Goes to the position after an example's move and illustrates it; clicking the active example again clears it.
    func showExample(_ e: GameLesson.Example, at id: Int, title: String) {
        let focus = LessonFocus(nodeID: id, title: title, example: e)
        if lessonFocus == focus { lessonFocus = nil; return }
        goto(id)
        guard currentID == id else { return }
        lessonFocus = focus
    }

    func clearLessonFocus() { lessonFocus = nil }

    private func didMove() {
        refreshEngine()
        persist()
        playSession?.positionChanged()
    }

    // MARK: Moves

    func play(_ move: Move) {
        if let s = playSession, !s.acceptsInput { return }
        do {
            let id = try game.addMove(move, after: currentID)
            currentID = id
            playSession?.noteMove(to: id)
            didMove()
        } catch { showToast("That move isn't legal.") }
    }

    /// Plays the engine's suggestion (UCI) from the position before the current node.
    func playBest(fromParentOf id: Int) {
        guard playSession == nil, let parent = game.nodes[id].parent,
              let uci = review.entries[parent]?.best,
              let move = game.nodes[parent].position.move(fromUCI: uci) else { return }
        currentID = parent
        play(move)
    }

    /// Plays the first `count` moves of an engine line from the current position.
    func playLine(_ pv: [String], count: Int) {
        for u in pv.prefix(count) {
            guard let m = position.move(fromUCI: u) else { break }
            play(m)
        }
    }

    /// Plays the first `count` moves of `pv` as a variation starting at node `id`.
    func playLine(_ pv: [String], count: Int, from id: Int) {
        guard playSession == nil, game.nodes.indices.contains(id) else { return }
        currentID = id
        playLine(pv, count: count)
    }

    func playEngineMove(_ uci: String) {
        if let m = position.move(fromUCI: uci) { play(m) }
    }

    func promote(_ id: Int) { game.promote(id); layoutCache = [:]; persist() }

    func deleteFrom(_ id: Int) {
        guard id != 0, let parent = game.nodes[id].parent else { return }
        endPlay()                                    // node ids change
        let path = game.path(to: parent)
        var choices: [Int] = []
        for (a, b) in zip(path, path.dropFirst()) { choices.append(game.nodes[a].children.firstIndex(of: b) ?? 0) }
        let tipMoves = game.moves(to: lineTip)
        game.delete(id)
        let survivor = game.locate(moves: tipMoves)   // the same line, as far as it survives
        lineTip = game.moves(to: survivor).count == tipMoves.count ? survivor : (game.mainline(from: survivor).last ?? survivor)
        var cur = 0
        for c in choices {
            let kids = game.nodes[cur].children
            guard kids.indices.contains(c) else { break }
            cur = kids[c]
        }
        layoutCache = [:]
        review.reset()
        ask.reset()
        lessonFocus = nil; lessonPlayer = nil
        currentID = cur
        didMove()
    }

    // MARK: Loading

    func loadGame(_ g: Game, flipped: Bool = false, toast: String? = nil) {
        endPlay()
        engine.clearLines()
        review.reset()
        ask.reset()
        game = g
        lineTip = g.mainline().last ?? 0
        currentID = 0
        self.flipped = flipped
        layoutCache = [:]
        epoch += 1
        engine.newGame()
        didMove()
        if let toast { showToast(toast) }
    }

    func loadPosition(_ p: Position, flipped: Bool = false) {
        loadGame(Game(startPosition: p), flipped: flipped, toast: "Position loaded")
    }

    func newGame() {
        loadGame(Game(), toast: "New game")
    }

    func loadFEN(_ text: String) -> Bool {
        guard let p = try? Position(fen: text) else { return false }
        loadPosition(p)
        return true
    }

    // MARK: Export

    func copy(_ string: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        showToast("\(label) copied")
    }

    func copyFEN() { copy(position.fen, label: "FEN") }
    func copyPGN() { copy(PGN.export(game), label: "PGN") }

    // MARK: Engine

    func refreshEngine() {
        guard !review.running else { return }
        if game.gameEnd(at: currentID) != nil { engine.markGameOver(position) }
        else if engineEnabled && !hidesEvaluation { engine.analyze(position, history: game.engineHistory(to: currentID)) }
        else { engine.stopLive() }
    }

    func startReview() {
        guard engine.isAvailable else { showToast("The engine is not available in this build."); return }
        let line = game.fullLine(through: lineTip)
        guard line.count > 1 else { showToast("Play or load some moves first."); return }
        review.start(game: game, line: line, engine: engine) { [weak self] finished in
            guard let self else { return }
            self.showToast(finished ? "Review complete" : "Review cancelled")
            self.refreshEngine()
        }
    }

    func cancelReview() {
        review.cancel()
    }

    // MARK: Toasts

    func showToast(_ text: String) {
        toastText = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { self?.toastText = nil }
        }
    }

    // MARK: Import routing

    func openImporter(_ tab: ImportTab = .pgn) {
        importer.tab = tab
        showImport = true
    }

    /// Opens the Import sheet on the Set Up tab, seeded from the board on screen.
    func openSetup() {
        importer.seedSetup(from: position, flipped: flipped)
        openImporter(.setup)
    }

    /// Handles a pasted/dropped PGN or FEN text.
    func handleText(_ text: String, fromClipboard: Bool = true) {
        switch ImportDetect.classify(text) {
        case .fen(let fen):
            if loadFEN(fen) { return }
            importer.fenText = fen
            openImporter(.fen)
        case .pgn(let pgn):
            let games = PGN.parse(pgn)
            if games.count == 1, games[0].issue == nil, games[0].game.nodes.count > 1 {
                loadGame(games[0].game, toast: "Game loaded")
            } else {
                importer.pgnText = pgn
                openImporter(.pgn)
            }
        case .unknown:
            showToast("That doesn't look like a PGN or FEN.")
        }
    }

    func handleImage(_ image: NSImage) {
        importer.recognize(image: image)
        showImport = true
    }

    func handleFileURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            if let img = NSImage(contentsOf: url) { handleImage(img) } else { showToast("That image could not be read.") }
            return
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            showToast("That file could not be read.")
            return
        }
        let games = PGN.parse(text)
        if games.isEmpty { showToast("No chess game found in \(url.lastPathComponent)."); return }
        if games.count == 1, games[0].issue == nil {
            loadGame(games[0].game, toast: "Game loaded")
        } else {
            importer.pgnText = text
            openImporter(.pgn)
        }
    }

    /// ⌘V anywhere: image → screenshot flow, text → FEN or PGN.
    /// Outside the import sheet the paste goes through the same confirmation card as a drop.
    func handlePasteboard(_ pb: NSPasteboard = .general) {
        let confirm = !showImport
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            if confirm { stageFile(url) } else { handleFileURL(url) }
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            if confirm { stageText(text) } else { handleText(text) }
            return
        }
        if let image = NSImage(pasteboard: pb) {
            if confirm { stageImage(image) } else { handleImage(image) }
            return
        }
        showToast("Nothing to paste. Copy a PGN, a FEN or a board screenshot first.")
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var pgn: String
        var path: [Int]       // child index chosen at each step from the root
        var flipped: Bool
        var tip: [Int]? = nil  // child indices to the shown line's end (absent in older saves)
    }

    private static let saveKey = "lastGame.v1"

    func persist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let path = self.game.path(to: self.currentID)
            var choices: [Int] = []
            for (a, b) in zip(path, path.dropFirst()) {
                choices.append(self.game.nodes[a].children.firstIndex(of: b) ?? 0)
            }
            let tipPath = self.game.path(to: self.lineTip)
            var tipChoices: [Int] = []
            for (a, b) in zip(tipPath, tipPath.dropFirst()) {
                tipChoices.append(self.game.nodes[a].children.firstIndex(of: b) ?? 0)
            }
            let saved = Saved(pgn: PGN.export(self.game), path: choices, flipped: self.flipped, tip: tipChoices)
            if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.saveKey) }
        }
    }

    private static func restore() -> (game: Game, node: Int, flipped: Bool, tip: Int?)? {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              let parsed = PGN.parse(saved.pgn).first else { return nil }
        let g = parsed.game
        func follow(_ choices: [Int]) -> Int {
            var cur = 0
            for c in choices {
                let kids = g.nodes[cur].children
                guard kids.indices.contains(c) else { break }
                cur = kids[c]
            }
            return cur
        }
        return (g, follow(saved.path), saved.flipped, saved.tip.map(follow))
    }
}

/// A summary example shown on the board (see `AppModel.showExample`).
struct LessonFocus: Equatable {
    var nodeID: Int
    var title: String                     // the concept name, or "Turning point"
    var example: GameLesson.Example
    var why: String? { example.why }
    var arrows: [GameLesson.Example.Arrow] { example.arrows }
    var squares: [Square] { example.squares }
}
