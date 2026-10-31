import Foundation
import AppKit
import UniformTypeIdentifiers
import ChessCore
import BoardVision

/// Drag-and-drop import: whatever lands on the window is read into a `PendingImport`
/// and shown on a confirmation card instead of replacing the current game straight away.
extension AppModel {
    func handleDropped(_ item: DroppedItem?) {
        switch item {
        case .file(let url)?: stageFile(url)
        case .image(let image)?: stageImage(image)
        case .link(let url)?: stageLink(url)
        case .text(let text)?: stageText(text)
        case nil: showToast("That couldn't be read.")
        }
    }

    // MARK: Staging

    private func begin(_ pending: PendingImport) {
        pendingTask?.cancel()
        pendingTask = nil
        pendingImport = pending
    }

    private func fail(_ message: String) {
        pendingImport?.status = .failed(message)
    }

    func stageFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image) {
            if let img = NSImage(contentsOf: url) { stageImage(img) } else { showToast("That image could not be read.") }
            return
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            showToast("That file could not be read.")
            return
        }
        if PGN.parse(text).isEmpty {
            if case .fen = ImportDetect.classify(text) { stageText(text) } else { showToast("No chess game found in \(url.lastPathComponent).") }
            return
        }
        stagePGN(text, requireMoves: false)
    }

    func stageText(_ text: String) {
        if let url = GameLink.url(in: text) { stageLink(url); return }
        switch ImportDetect.classify(text) {
        case .fen(let fen):
            if var p = try? Position(fen: fen) {
                // A bare piece placement has no castling info: keep what is possible.
                if fen.split(separator: " ").count <= 2 { p.castling = ScreenshotDraft.possibleCastling(p.board) }
                begin(PendingImport(status: .ready, content: .position(p), title: "Position",
                                    detail: "\(p.turn == .white ? "White" : "Black") to move", edit: .fen(fen)))
            } else {
                importer.fenText = fen
                openImporter(.fen)
            }
        case .pgn(let pgn):
            stagePGN(pgn, requireMoves: true)
        case .unknown:
            showToast("That doesn't look like a PGN or FEN.")
        }
    }

    /// One clean game gets a confirmation card; anything ambiguous (several games, illegal moves) opens the PGN tab as before.
    private func stagePGN(_ pgn: String, requireMoves: Bool, flipped: Bool = false, source: String? = nil) {
        let games = PGN.parse(pgn)
        if games.count == 1, games[0].issue == nil, !requireMoves || games[0].game.nodes.count > 1 {
            stageGame(games[0].game, flipped: flipped, source: source, pgn: pgn)
        } else {
            pendingImport = nil
            importer.pgnText = pgn
            openImporter(.pgn)
        }
    }

    private func stageGame(_ game: Game, flipped: Bool, source: String?, pgn: String?) {
        let moves = game.mainline().count / 2          // plies rounded up to whole moves
        let detail = [moves > 0 ? "\(moves) move\(moves == 1 ? "" : "s")" : nil, source, game.result == "*" ? nil : game.result]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
        begin(PendingImport(status: .ready, content: .game(game), flipped: flipped,
                            title: PGN.title(of: game), detail: detail, edit: .pgn(pgn ?? PGN.export(game))))
    }

    func stageImage(_ image: NSImage) {
        begin(PendingImport(status: .working("Reading board\u{2026}"), title: "Screenshot", edit: .screenshot(image)))
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fail("That image could not be read.")
            return
        }
        pendingTask = Task { [weak self] in
            do {
                let result = try await BoardRecognizer().recognize(cg)
                if Task.isCancelled { return }
                self?.finishScreenshot(ImportModel.makeDraft(result))
            } catch {
                if Task.isCancelled { return }
                self?.fail(ImportModel.message(for: error))
            }
        }
    }

    private func finishScreenshot(_ draft: ScreenshotDraft) {
        pendingImport?.draft = draft
        do {
            try draft.position.validate()
        } catch {
            let why = (error as? ChessError)?.errorDescription ?? error.localizedDescription
            fail("The board was found but the position doesn't look right (\(why)). You can still correct it by hand.")
            return
        }
        let n = draft.uncertain.count
        pendingImport?.content = .position(draft.position)
        pendingImport?.flipped = draft.blackAtBottom
        pendingImport?.detail = ["Recognized from screenshot", "\(draft.sideToMove == .white ? "White" : "Black") to move",
                                 n > 0 ? "\(n) square\(n == 1 ? "" : "s") uncertain" : nil]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
        pendingImport?.status = .ready
    }

    func stageLink(_ url: URL) {
        guard let link = GameLink.parse(url) else { showToast("That link can't be imported."); return }
        begin(PendingImport(status: .working("Fetching\u{2026}"), title: link.source, detail: url.absoluteString))
        pendingTask = Task { [weak self] in
            do {
                let result = try await LinkFetcher.fetch(link)
                if Task.isCancelled { return }
                self?.finishLink(result, link: link)
            } catch {
                if Task.isCancelled { return }
                self?.fail((error as? LinkFetcher.Failure)?.message ?? "Couldn't reach that link.")
            }
        }
    }

    private func finishLink(_ result: LinkFetcher.Result, link: GameLink) {
        switch result {
        case .game(let g):
            stageGame(g, flipped: link.flipped, source: link.source, pgn: nil)
        case .text(let text):
            let notFound = "No chess game found at that link."
            switch ImportDetect.classify(text) {
            case .pgn(let pgn):
                if link.kind == .generic, !PGN.parse(pgn).contains(where: { $0.game.nodes.count > 1 }) { fail(notFound); return }
                stagePGN(pgn, requireMoves: true, flipped: link.flipped, source: link.source)
            case .fen(let fen) where link.kind == .generic:
                stageText(fen)
            default:
                fail(link.kind == .generic ? notFound : "Couldn't read that \(link.source) game.")
            }
        }
    }

    // MARK: Card actions

    func confirmPendingImport() {
        guard let p = pendingImport, case .ready = p.status, let content = p.content else { return }
        pendingImport = nil
        switch content {
        case .game(let g): loadGame(g, flipped: p.flipped, toast: "Game loaded")
        case .position(let pos): loadPosition(pos, flipped: p.flipped)
        }
    }

    func cancelPendingImport() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingImport = nil
    }

    /// Hands the import over to the full import sheet.
    func editPendingImport() {
        guard let p = pendingImport, let edit = p.edit else { return }
        cancelPendingImport()
        switch edit {
        case .pgn(let text):
            importer.pgnText = text
            openImporter(.pgn)
        case .fen(let text):
            importer.fenText = text
            openImporter(.fen)
        case .screenshot(let image):
            if let draft = p.draft { importer.adopt(image: image, draft: draft) } else { importer.recognize(image: image) }
            showImport = true
        }
    }
}
