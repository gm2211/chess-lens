import SwiftUI
import UniformTypeIdentifiers
import ChessCore

struct ImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var picker: PickerKind?

    enum PickerKind { case pgn, image }

    static var pgnTypes: [UTType] {
        [UTType(filenameExtension: "pgn") ?? .plainText, .plainText, .text]
    }

    var body: some View {
        @Bindable var importer = app.importer
        VStack(spacing: 0) {
            HStack {
                Text("Import").font(.display(26))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink2)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            Picker("Import type", selection: $importer.tab) {
                ForEach(ImportTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.bottom, 12)

            Divider()
            ScrollView {
                Group {
                    switch importer.tab {
                    case .pgn: PGNTab(openFile: { picker = .pgn }, close: { dismiss() })
                    case .fen: FENTab(close: { dismiss() })
                    case .screenshot: ScreenshotTab(chooseImage: { picker = .image }, close: { dismiss() })
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 660, height: 600)
        .background(Theme.surface)
        .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                      allowedContentTypes: picker == .image ? [.image] : Self.pgnTypes) { result in
            guard case .success(let url) = result else { return }
            let kind = picker
            picker = nil
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if kind == .image {
                if let img = NSImage(contentsOf: url) { app.importer.recognize(image: img) }
                else { app.showToast("That image could not be read.") }
            } else if let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                app.importer.pgnText = text
            } else {
                app.showToast("That file could not be read.")
            }
        }
    }
}

// MARK: - PGN

private struct PGNTab: View {
    @Environment(AppModel.self) private var app
    let openFile: () -> Void
    let close: () -> Void

    var body: some View {
        @Bindable var importer = app.importer
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a game in PGN format. Files with several games are fine.")
                .font(.system(size: 13)).foregroundStyle(Theme.ink3)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $importer.pgnText)
                    .font(.mono(12.5, weight: .regular))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 170)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1))
                if importer.pgnText.isEmpty {
                    Text("[Event \"Casual game\"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *")
                        .font(.mono(12.5, weight: .regular)).foregroundStyle(Theme.ink3.opacity(0.7))
                        .padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                Button("Paste from clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) { importer.pgnText = s }
                    else { app.showToast("The clipboard has no text.") }
                }
                Button("Open file\u{2026}", action: openFile)
                Button("Clear") { importer.pgnText = "" }
                Button("Try the Opera Game") { importer.pgnText = SampleGames.opera }
            }
            .buttonStyle(QuietButtonStyle())

            if importer.games.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(importer.games.enumerated()), id: \.offset) { i, g in
                        Button { importer.selectedGame = i } label: {
                            HStack(spacing: 10) {
                                Text(g.title).font(.system(size: 13.5)).lineLimit(1)
                                if let e = g.game.header("Event"), e != "?" { Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1) }
                                Spacer()
                                Text(g.game.result).font(.mono(12.5)).foregroundStyle(Theme.ink3)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(importer.selectedGame == i ? Theme.accentSoft : .clear)
                            .overlay(alignment: .leading) { if importer.selectedGame == i { Rectangle().fill(Theme.accent).frame(width: 3) } }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .frame(maxHeight: 170)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            preview

            HStack {
                if let g = importer.parsedSelected, g.issue != nil, g.game.nodes.count > 1 {
                    Button("Load the legal part (\(g.game.mainline().count - 1) moves)") { load(g, partial: true) }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Load game") { if let g = importer.parsedSelected { load(g, partial: false) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(importer.parsedSelected == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let importer = app.importer
        let trimmed = importer.pgnText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else if let g = importer.parsedSelected {
            HStack(alignment: .top, spacing: 14) {
                MiniBoard(board: g.game.nodes[g.game.mainline().last ?? 0].position.board)
                    .frame(width: 150, height: 150)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    if let issue = g.issue {
                        Notice(kind: .warn, text: issue.message + ".")
                        Text(g.game.nodes.count > 1 ? "Everything before it can still be loaded." : "There are no legal moves to load.")
                            .font(.system(size: 13)).foregroundStyle(Theme.ink3)
                    } else {
                        Notice(kind: .ok, text: "Ready: \(g.title), \(g.game.mainline().count - 1) moves, \(g.game.result).")
                    }
                }
            }
        } else {
            Notice(kind: .error, text: "No game found. Check that the text is PGN: a header such as [Event \"\u{2026}\"] or numbered moves like 1. e4 e5.")
        }
    }

    private func load(_ g: ParsedGame, partial: Bool) {
        let moves = g.game.mainline().count - 1
        app.loadGame(g.game, toast: partial ? "Loaded the legal part (\(moves) moves)" : "Game loaded")
        app.importer.reset()
        close()
    }
}

// MARK: - FEN

private struct FENTab: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void

    private let examples: [(String, String)] = [
        ("Start position", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"),
        ("Lucena position", "1K1k4/1P6/8/8/8/8/r7/2R5 w - - 0 1"),
        ("Philidor position", "4k3/R7/4K3/4P3/8/8/8/5r2 b - - 0 1"),
    ]

    var body: some View {
        @Bindable var importer = app.importer
        let status = importer.fenStatus
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a FEN, or just the piece placement.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            TextField("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", text: $importer.fenText)
                .textFieldStyle(.roundedBorder).font(.mono(12.5, weight: .regular))
                .autocorrectionDisabled()
                .onSubmit { loadIfValid(status) }
            switch status {
            case .empty: Notice(kind: .info, text: "Waiting for a FEN.")
            case .invalid(let why): Notice(kind: .error, text: why + ".")
            case .valid(let p): Notice(kind: .ok, text: "Valid position \u{2014} \(p.turn == .white ? "White" : "Black") to move.")
            }
            HStack(alignment: .top, spacing: 14) {
                MiniBoard(board: previewBoard(status)).frame(width: 190, height: 190)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try an example").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                    ForEach(examples, id: \.0) { name, fen in
                        Button(name) { importer.fenText = fen }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
            Button("Load position") { loadIfValid(status) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled({ if case .valid = status { false } else { true } }())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func previewBoard(_ s: ImportModel.FENStatus) -> [Piece?] {
        if case .valid(let p) = s { return p.board }
        return [Piece?](repeating: nil, count: 64)
    }

    private func loadIfValid(_ s: ImportModel.FENStatus) {
        guard case .valid(let p) = s else { return }
        app.loadPosition(p)
        app.importer.reset()
        close()
    }
}

// MARK: - Screenshot

private struct ScreenshotTab: View {
    @Environment(AppModel.self) private var app
    let chooseImage: () -> Void
    let close: () -> Void
    @State private var dropOver = false

    var body: some View {
        let importer = app.importer
        VStack(alignment: .leading, spacing: 14) {
            switch importer.shotState {
            case .idle: idle
            case .working: working
            case .failed(let msg): failed(msg)
            case .confirm: ScreenshotConfirmView(close: close)
            }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30)).foregroundStyle(Theme.ink2)
                Text("**Paste a board screenshot (\u{2318}V)**").font(.system(size: 14))
                Text("or drop an image file here. You can paste anywhere in Chess Lens.")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink3)
                Button("Choose image\u{2026}", action: chooseImage).buttonStyle(QuietButtonStyle())
            }
            .foregroundStyle(Theme.ink2)
            .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 16)
            .background(dropOver ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(dropOver ? Theme.accent : Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropOver) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in app.handleFileURL(url) }
                }
                return true
            }
            Text("Chess Lens reads the pieces on your Mac, then you check and correct the result before anything is loaded.")
                .font(.system(size: 13)).foregroundStyle(Theme.ink3)
            Button("Set up a position by hand") { app.importer.startManualDraft() }.buttonStyle(QuietButtonStyle())
        }
    }

    private var working: some View {
        HStack(spacing: 16) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the board\u{2026}") }
                Button("Cancel") { app.importer.cancelScreenshot(); app.importer.shotState = .idle }.buttonStyle(QuietButtonStyle())
            }
            Spacer()
        }
    }

    private func failed(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                thumbnail
                Notice(kind: .error, text: msg)
            }
            HStack {
                Button("Try another image", action: chooseImage).buttonStyle(QuietButtonStyle())
                Button("Set up a position by hand") { app.importer.startManualDraft() }.buttonStyle(QuietButtonStyle())
            }
            Text("Everything else in Chess Lens works without screenshot reading: paste a PGN or FEN, or set up a position by hand.")
                .font(.system(size: 13)).foregroundStyle(Theme.ink3)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = app.importer.shotImage {
            Image(nsImage: img).resizable().scaledToFit()
                .frame(maxWidth: 160, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2, lineWidth: 1))
        }
    }
}

// MARK: - Confirm

struct ScreenshotConfirmView: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void

    private enum Tool: Hashable { case none, erase, piece(Piece) }
    @State private var tool: Tool = .none
    @State private var placementText = ""

    private var draftBinding: Binding<ScreenshotDraft> {
        Binding(get: { app.importer.draft ?? ScreenshotDraft(board: [Piece?](repeating: nil, count: 64), uncertain: [], sideToMove: .white, castling: [], blackAtBottom: false, confidence: 1) },
                set: { app.importer.draft = $0 })
    }

    var body: some View {
        let draft = draftBinding.wrappedValue
        let allowed = ScreenshotDraft.possibleCastling(draft.board)
        let validation: String? = { do { try draft.position.validate(); return nil } catch { return (error as? ChessError)?.errorDescription } }()

        VStack(alignment: .leading, spacing: 14) {
            if app.importer.shotImage != nil {
                Notice(kind: draft.uncertain.isEmpty ? .info : .warn,
                       text: draft.uncertain.isEmpty
                       ? "Check the pieces against your image and fix anything that's off."
                       : "Outlined squares were hard to read. Check them against your image.")
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    MiniBoard(board: draft.board, flipped: draft.blackAtBottom, uncertain: draft.uncertain) { sq in
                        var d = draftBinding.wrappedValue
                        switch tool {
                        case .none: return
                        case .erase: d.board[sq] = nil
                        case .piece(let p): d.board[sq] = p
                        }
                        d.uncertain.remove(sq)
                        d.castling.formIntersection(ScreenshotDraft.possibleCastling(d.board))
                        draftBinding.wrappedValue = d
                    }
                    .frame(width: 250, height: 250)
                    if let img = app.importer.shotImage {
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 120, maxHeight: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2, lineWidth: 1))
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PIECE PLACEMENT").font(.system(size: 11, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
                        TextField("", text: $placementText)
                            .textFieldStyle(.roundedBorder).font(.mono(12, weight: .regular)).autocorrectionDisabled()
                    }
                    HStack {
                        Text("Side to move").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                        Picker("Side to move", selection: Binding(get: { draft.sideToMove }, set: { draftBinding.wrappedValue.sideToMove = $0 })) {
                            Text("White").tag(Side.white)
                            Text("Black").tag(Side.black)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    }
                    HStack(spacing: 12) {
                        Text("Castling").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                        castle("K", .whiteKingside, allowed, draft)
                        castle("Q", .whiteQueenside, allowed, draft)
                        castle("k", .blackKingside, allowed, draft)
                        castle("q", .blackQueenside, allowed, draft)
                    }
                    Toggle("Show board from Black's side", isOn: Binding(get: { draft.blackAtBottom }, set: { draftBinding.wrappedValue.blackAtBottom = $0 }))
                        .font(.system(size: 13))
                    Button("Flip if wrong (rotate 180\u{00B0})") {
                        var d = draftBinding.wrappedValue
                        d.rotate180()
                        d.castling.formIntersection(ScreenshotDraft.possibleCastling(d.board))
                        draftBinding.wrappedValue = d
                    }.buttonStyle(QuietButtonStyle())
                }
            }
            Text("Pick a piece, then click squares to fix mistakes.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            palette
            if let validation { Notice(kind: .error, text: validation + ".") }
            HStack {
                Button("Load position") {
                    app.loadPosition(draft.position, flipped: draft.blackAtBottom)
                    app.importer.reset()
                    close()
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(validation != nil)
                .keyboardShortcut(.defaultAction)
                Button("Try another image") { app.importer.shotState = .idle; app.importer.draft = nil }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .onAppear { placementText = draft.placement }
        .onChange(of: draft.placement) { _, new in
            if let b = try? Position.parseBoard(placementText), b == draft.board { return }
            placementText = new
        }
        .onChange(of: placementText) { _, text in
            var d = draftBinding.wrappedValue
            if d.setPlacement(text), d.board != draftBinding.wrappedValue.board {
                d.castling.formIntersection(ScreenshotDraft.possibleCastling(d.board))
                draftBinding.wrappedValue = d
            }
        }
    }

    private func castle(_ label: String, _ flag: CastlingRights, _ allowed: CastlingRights, _ draft: ScreenshotDraft) -> some View {
        Toggle(label, isOn: Binding(get: { draft.castling.contains(flag) }, set: { on in
            if on { draftBinding.wrappedValue.castling.insert(flag) } else { draftBinding.wrappedValue.castling.remove(flag) }
        }))
        .toggleStyle(.checkbox).font(.system(size: 13)).disabled(!allowed.contains(flag))
    }

    private var palette: some View {
        let pieces: [Piece] = [Side.white, .black].flatMap { c in [PieceType.king, .queen, .rook, .bishop, .knight, .pawn].map { Piece(c, $0) } }
        return HStack(spacing: 2) {
            ForEach(pieces, id: \.self) { p in
                Button { tool = (tool == .piece(p)) ? .none : .piece(p) } label: {
                    Image(p.assetName).resizable().padding(2).frame(width: 34, height: 34)
                        .background(tool == .piece(p) ? Theme.hlSel : Theme.sqL, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(tool == .piece(p) ? Theme.accent : Theme.line, lineWidth: tool == .piece(p) ? 2 : 1))
                }.buttonStyle(.plain).accessibilityLabel(p.assetName)
            }
            Button { tool = (tool == .erase) ? .none : .erase } label: {
                Text("Erase").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).frame(height: 34)
                    .background(tool == .erase ? Theme.hlSel : Theme.surface, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(tool == .erase ? Theme.accent : Theme.line, lineWidth: tool == .erase ? 2 : 1))
            }.buttonStyle(.plain)
        }
    }
}
