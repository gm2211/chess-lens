import Foundation
import AppKit
import UniformTypeIdentifiers
import ChessCore

/// Something dropped on the window that is waiting for the user's go-ahead (or still being read).
struct PendingImport {
    enum Status {
        case working(String)
        case ready
        case failed(String)
    }

    enum Content {
        case game(Game)
        case position(Position)
    }

    /// Where "Edit…" / "Open editor" sends the import.
    enum Edit {
        case pgn(String)
        case fen(String)
        case screenshot(NSImage)
    }

    var status: Status
    var content: Content?
    var flipped = false
    var title: String
    var detail = ""
    var draft: ScreenshotDraft?
    var edit: Edit?

    /// Board shown on the card: the start position for a position, the final position for a game.
    var previewBoard: [Piece?] {
        switch content {
        case .game(let g)?: g.nodes[g.mainline().last ?? 0].position.board
        case .position(let p)?: p.board
        case nil: [Piece?](repeating: nil, count: 64)
        }
    }
}

/// What was dropped, in the order the window prefers to read it.
enum DroppedItem {
    case file(URL)
    case image(NSImage)
    case link(URL)
    case text(String)
}

@MainActor
enum DropLoader {
    /// Picks the richest thing in the drop (file, then image data, then web link, then text) and loads it.
    /// Returns false when nothing in the drop is usable. `completion` gets nil if loading fails.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor (DroppedItem?) -> Void) -> Bool {
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in completion(url.map(DroppedItem.file)) }
            }
            return true
        }
        for p in providers {
            guard let id = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
            p.loadDataRepresentation(forTypeIdentifier: id) { data, _ in
                Task { @MainActor in completion(data.flatMap { NSImage(data: $0) }.map(DroppedItem.image)) }
            }
            return true
        }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in completion(url.map(DroppedItem.link)) }
            }
            return true
        }
        if let p = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = p.loadObject(ofClass: String.self) { s, _ in
                Task { @MainActor in completion(s.map(DroppedItem.text)) }
            }
            return true
        }
        return false
    }
}

/// Downloads a game from a link. Network access is the only reason this isn't in ChessCore.
enum LinkFetcher {
    enum Result {
        case game(Game)
        case text(String)
    }

    struct Failure: Error { let message: String }

    static let maxBytes = 2_000_000

    static func fetch(_ link: GameLink) async throws -> Result {
        var req = URLRequest(url: link.fetchURL, timeoutInterval: 10)
        req.setValue("ChessLens/1.0", forHTTPHeaderField: "User-Agent")
        if let accept = link.accept { req.setValue(accept, forHTTPHeaderField: "Accept") }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        do {
            data = try await download(req, with: session, link: link)
        } catch let f as Failure {
            throw f
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError where e.code == .timedOut {
            throw Failure(message: "That link took too long to respond.")
        } catch {
            throw Failure(message: link.kind.isChessCom ? "Couldn't read that chess.com game." : "Couldn't reach that link.")
        }

        switch link.kind {
        case .chessCom:
            do { return .game(try ChessComGame.parse(json: data)) } catch { throw Failure(message: "Couldn't read that chess.com game.") }
        case .generic:
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<") else {
                throw Failure(message: "No chess game found at that link.")
            }
            return .text(text)
        case .lichessGame, .lichessStudy:
            guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "Couldn't read that lichess game.") }
            return .text(text)
        }
    }

    private static func download(_ req: URLRequest, with session: URLSession, link: GameLink) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch link.kind {
            case .lichessGame, .lichessStudy:
                throw Failure(message: http.statusCode == 404 ? "Lichess has no game at that link." : "Couldn't fetch that lichess game.")
            case .chessCom:
                throw Failure(message: "Couldn't read that chess.com game.")
            case .generic:
                throw Failure(message: "No chess game found at that link.")
            }
        }
        guard response.expectedContentLength <= Int64(maxBytes) else { throw Failure(message: "No chess game found at that link.") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw Failure(message: "No chess game found at that link.") }
        }
        return data
    }
}

extension GameLink.Kind {
    var isChessCom: Bool { if case .chessCom = self { true } else { false } }
}
