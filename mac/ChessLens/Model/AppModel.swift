import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers
import ChessCore

enum SideTab: String, CaseIterable, Identifiable {
    case moves = "Moves", engine = "Engine", review = "Review"
    var id: String { rawValue }
}

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
    private(set) var currentID = 0
    private(set) var epoch = 0                       // bumps when a different game is loaded
    var flipped = false

    // MARK: UI state
    var sideTab: SideTab = .moves
    var showInspector = true
    var engineEnabled = true { didSet { if engineEnabled != oldValue { refreshEngine() } } }
    var showImport = false
    var showFileImporter = false
    var isDropTargeted = false
    private(set) var toastText: String?

    let engine = EngineController()
    let review = ReviewModel()
    let importer = ImportModel()

    private var layoutCache: [Int: [PieceInstance]] = [:]
    private var toastTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        if let saved = Self.restore() {
            game = saved.game
            currentID = saved.node
            flipped = saved.flipped
        } else {
            game = SampleGames.operaGame
        }
        layoutCache = [:]
        refreshEngine()
    }

    // MARK: Derived

    var node: GameNode { game.nodes[currentID] }
    var position: Position { node.position }
    var lastMove: Move? { node.move }
    var canGoBack: Bool { node.parent != nil }
    var canGoForward: Bool { !node.children.isEmpty }

    var title: String { PGN.title(of: game) }
    var subtitle: String {
        var parts: [String] = []
        if let e = game.header("Event"), e != "?", e != title { parts.append(e) }
        if let s = game.header("Site"), s != "?" { parts.append(s) }
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
        if engineEnabled, engine.linesFEN == position.fen, let l = engine.lines.first { return l.eval }
        return review.entries[currentID]?.eval
    }

    var terminalEval: Eval? {
        let p = position
        if p.isCheckmate { return .checkmate(winner: p.turn.opposite) }
        if p.isStalemate || p.isInsufficientMaterial { return .cp(0) }
        return nil
    }

    // MARK: Navigation

    func goto(_ id: Int) {
        guard game.nodes.indices.contains(id), id != currentID else { return }
        currentID = id
        didMove()
    }

    func back() { if let p = node.parent { goto(p) } }
    func forward() { if let c = node.children.first { goto(c) } }
    func first() { goto(0) }
    func last() { goto(game.mainline(from: currentID).last ?? currentID) }

    func toggleFlip() { flipped.toggle(); persist() }

    private func didMove() {
        refreshEngine()
        persist()
    }

    // MARK: Moves

    func play(_ move: Move) {
        do {
            let id = try game.addMove(move, after: currentID)
            currentID = id
            didMove()
        } catch { showToast("That move isn't legal.") }
    }

    /// Plays the engine's suggestion (UCI) from the position before the current node.
    func playBest(fromParentOf id: Int) {
        guard let parent = game.nodes[id].parent,
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

    func playEngineMove(_ uci: String) {
        if let m = position.move(fromUCI: uci) { play(m) }
    }

    func promote(_ id: Int) { game.promote(id); layoutCache = [:]; persist() }

    func deleteFrom(_ id: Int) {
        guard id != 0, let parent = game.nodes[id].parent else { return }
        let path = game.path(to: parent)
        var choices: [Int] = []
        for (a, b) in zip(path, path.dropFirst()) { choices.append(game.nodes[a].children.firstIndex(of: b) ?? 0) }
        game.delete(id)
        var cur = 0
        for c in choices {
            let kids = game.nodes[cur].children
            guard kids.indices.contains(c) else { break }
            cur = kids[c]
        }
        layoutCache = [:]
        review.reset()
        currentID = cur
        didMove()
    }

    // MARK: Loading

    func loadGame(_ g: Game, flipped: Bool = false, toast: String? = nil) {
        engine.clearLines()
        review.reset()
        game = g
        currentID = 0
        self.flipped = flipped
        layoutCache = [:]
        epoch += 1
        engine.newGame()
        didMove()
        sideTab = .moves
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
        if engineEnabled { engine.analyze(position) } else { engine.stopLive() }
    }

    func startReview() {
        guard engine.isAvailable else { showToast("The engine is not available in this build."); return }
        let line = game.fullLine(through: currentID)
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
    func handlePasteboard(_ pb: NSPasteboard = .general) {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            handleFileURL(url)
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            handleText(text)
            return
        }
        if let image = NSImage(pasteboard: pb) {
            handleImage(image)
            return
        }
        showToast("Nothing to paste. Copy a PGN, a FEN or a board screenshot first.")
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var pgn: String
        var path: [Int]       // child index chosen at each step from the root
        var flipped: Bool
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
            let saved = Saved(pgn: PGN.export(self.game), path: choices, flipped: self.flipped)
            if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.saveKey) }
        }
    }

    private static func restore() -> (game: Game, node: Int, flipped: Bool)? {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              let parsed = PGN.parse(saved.pgn).first else { return nil }
        let g = parsed.game
        var cur = 0
        for c in saved.path {
            let kids = g.nodes[cur].children
            guard kids.indices.contains(c) else { break }
            cur = kids[c]
        }
        return (g, cur, saved.flipped)
    }
}
