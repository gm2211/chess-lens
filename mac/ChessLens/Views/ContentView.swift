import SwiftUI
import UniformTypeIdentifiers
import ChessCore

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            BoardColumn()
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            if app.showInspector {
                Divider()
                InspectorView()
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.showInspector)
            .navigationTitle(app.title)
            .navigationSubtitle(app.subtitle)
            .toolbar { toolbar }
            .sheet(isPresented: $app.showImport) { ImportSheet() }
            .fileImporter(isPresented: $app.showFileImporter, allowedContentTypes: ImportSheet.pgnTypes) { result in
                if case .success(let url) = result { app.handleFileURL(url) }
            }
            .onDrop(of: [.fileURL, .plainText], isTargeted: $app.isDropTargeted) { providers in handleDrop(providers) }
            .overlay { if app.isDropTargeted { dropOverlay } }
            .overlay(alignment: .bottom) { toast }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
            .onAppear { focused = true; PasteMonitor.install(app) }
            .onChange(of: app.showImport) { _, shown in if !shown { focused = true } }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var app = app
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.openImporter() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Import a game, position or screenshot")
            Button { app.newGame() } label: { Label("New Game", systemImage: "plus") }
                .help("Start a new game")
            Button { app.toggleFlip() } label: { Label("Flip Board", systemImage: "arrow.up.arrow.down") }
                .help("Flip the board (F)")
            Toggle(isOn: $app.engineEnabled) { Label("Engine", systemImage: "cpu") }
                .help("Turn the engine on or off")
                .disabled(!app.engine.isAvailable)
            Menu {
                Button("Copy FEN") { app.copyFEN() }
                Button("Copy PGN") { app.copyPGN() }
            } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the position or game")
            Button { app.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the side panel")
        }
    }

    // MARK: Pieces

    private var toast: some View {
        Group {
            if let t = app.toastText {
                Text(t)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toastText)
    }

    private var dropOverlay: some View {
        ZStack {
            Theme.accentSoft.opacity(0.7)
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 34))
                Text("Drop a PGN file or a board screenshot").font(.display(24))
            }
            .foregroundStyle(Theme.ink)
            .padding(30)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Input

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) || press.modifiers.contains(.option) { return .ignored }
        switch press.key {
        case .leftArrow: app.back()
        case .rightArrow: app.forward()
        case .upArrow, .home: app.first()
        case .downArrow, .end: app.last()
        default:
            if press.characters.lowercased() == "f" { app.toggleFlip() } else { return .ignored }
        }
        return .handled
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in app.handleFileURL(url) }
                }
                break
            } else if p.canLoadObject(ofClass: String.self) {
                handled = true
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s else { return }
                    Task { @MainActor in app.handleText(s) }
                }
                break
            }
        }
        return handled
    }
}

// MARK: - Board column

struct BoardColumn: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let barW: CGFloat = 26, gap: CGFloat = 10
                let side = max(160, min(geo.size.height, geo.size.width - barW - gap))
                HStack(spacing: gap) {
                    EvalBar(eval: app.barEval, flipped: app.flipped)
                        .frame(height: side)
                    BoardView(side: side)
                }
                .frame(width: side + barW + gap, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            NavigationRow()
            CoachBar()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

private struct NavigationRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            navButton("backward.end.fill", "First position (Home)", enabled: app.canGoBack) { app.first() }
            navButton("chevron.left", "Previous move (\u{2190})", enabled: app.canGoBack) { app.back() }
            navButton("chevron.right", "Next move (\u{2192})", enabled: app.canGoForward) { app.forward() }
            navButton("forward.end.fill", "Last position (End)", enabled: app.canGoForward) { app.last() }
        }
        .frame(maxWidth: 520)
        .padding(.leading, 36)
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct CoachBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let accent = borderColor
        HStack(spacing: 10) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 44)
        .frame(maxWidth: 520 + 36, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
        .padding(.leading, 0)
        .animation(.easeOut(duration: 0.15), value: app.currentID)
    }

    private var borderColor: Color { Theme.line2 }

    @ViewBuilder
    private var content: some View {
        let pos = app.position
        if pos.isCheckmate {
            Text("Checkmate \u{2014} **\(pos.turn == .white ? "Black" : "White")** wins").font(.system(size: 14)).foregroundStyle(Theme.ink2)
        } else if pos.isStalemate {
            Text("Stalemate \u{2014} the game is drawn").font(.system(size: 14)).foregroundStyle(Theme.ink2)
        } else if pos.isInsufficientMaterial {
            Text("Draw by insufficient material").font(.system(size: 14)).foregroundStyle(Theme.ink2)
        } else {
            Circle().fill(pos.turn == .white ? Color(red: 0.96, green: 0.96, blue: 0.94) : Color(red: 0.106, green: 0.133, blue: 0.125))
                .overlay(Circle().stroke(Theme.ink2, lineWidth: 1.5)).frame(width: 12, height: 12)
            Text("**\(pos.turn == .white ? "White" : "Black")** to move\(pos.isCheck ? " \u{2014} in check" : "")")
                .font(.system(size: 14)).foregroundStyle(Theme.ink2)
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Picker("Panel", selection: $app.sideTab) {
                ForEach(SideTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            switch app.sideTab {
            case .moves: MovesPanel()
            case .engine: EnginePanel()
            case .review: ReviewPanel()
            }
        }
        .background(Theme.surface)
    }
}

private struct MovesPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.title).font(.display(21)).foregroundStyle(Theme.ink).lineLimit(2)
                let sub = [app.game.header("Date").flatMap { $0.contains("?") ? nil : $0 }, PGN.meaningful(app.game.header("Event")).flatMap { $0 == app.title ? nil : $0 }, app.game.result == "*" ? nil : app.game.result]
                    .compactMap { $0 }.joined(separator: " \u{00B7} ")
                if !sub.isEmpty { Text(sub).font(.system(size: 13)).foregroundStyle(Theme.ink3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            MoveListView()
            Divider()
            HStack(spacing: 8) {
                Button { app.copyFEN() } label: { Label("Copy FEN", systemImage: "doc.on.doc") }.buttonStyle(QuietButtonStyle())
                Button { app.copyPGN() } label: { Label("Copy PGN", systemImage: "doc.on.doc") }.buttonStyle(QuietButtonStyle())
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            Text("Pieces: cburnett by Colin M.L. Burnett (CC BY-SA 3.0). Engine: Stockfish 18 (GPLv3).")
                .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}
