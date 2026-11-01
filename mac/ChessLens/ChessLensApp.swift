import SwiftUI
import AppKit
import ChessCore

@main
struct ChessLensApp: App {
    @State private var model = AppModel()

    init() {
        // Writing to a dead engine process must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("Étude", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 620)
                .onOpenURL { model.handleFileURL($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    Task { await model.engine.shutdown() }
                }
        }
        .defaultSize(width: 1160, height: 780)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            TabView {
                EngineSettingsForm(settings: model.engine.settings)
                    .padding(20).frame(width: 380)
                    .tabItem { Label("Engine", systemImage: "cpu") }
                AIProvidersView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            }
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Étude") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Game") { model.newGame() }.keyboardShortcut("n")
            Button("Open PGN\u{2026}") { model.showFileImporter = true }.keyboardShortcut("o")
            Button("Import\u{2026}") { model.openImporter() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Paste Game or Position") { model.handlePasteboard() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Copy FEN") { model.copyFEN() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy PGN") { model.copyPGN() }.keyboardShortcut("c", modifiers: [.command, .option])
        }
        CommandMenu("Board") {
            Button(model.playSession == nil ? "Continue Against Engine\u{2026}" : "Stop Playing Against Engine") { model.togglePlay() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Ask AI About This Position\u{2026}") { model.toggleAsk() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.canAskAI && !model.ask.isOpen)
            Divider()
            Button("Flip Board") { model.toggleFlip() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Previous Move") { model.back() }.keyboardShortcut("[")
            Button("Next Move") { model.forward() }.keyboardShortcut("]")
            Button("First Position") { model.first() }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Last Position") { model.last() }.keyboardShortcut("]", modifiers: [.command, .shift])
        }
        CommandMenu("Analysis") {
            Button(model.engineEnabled ? "Turn Engine Off" : "Turn Engine On") { model.engineEnabled.toggle() }
                .keyboardShortcut("e")
            Button("Review Game") { model.showInspector = true; model.startReview() }
                .keyboardShortcut("r")
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Side Panel" : "Show Side Panel") { model.showInspector.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}

enum AboutPanel {
    @MainActor static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        func add(_ s: String) { credits.append(NSAttributedString(string: s, attributes: body)) }
        add("A chess game importer and analysis board.\n\n")
        add("Analysis engine: Stockfish 18, \u{00A9} the Stockfish developers, licensed under the GNU General Public License v3 (a copy is included in the app bundle as Stockfish-Copying.txt). Source code: ")
        credits.append(NSAttributedString(string: "github.com/official-stockfish/Stockfish", attributes: body.merging([.link: URL(string: "https://github.com/official-stockfish/Stockfish/tree/sf_18")!]) { $1 }))
        add(" (tag sf_18).\n\nPieces: cburnett set by Colin M.L. Burnett, CC BY-SA 3.0.\n")
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// ⌘V should work anywhere in the window, not only when a particular view has focus.
@MainActor
enum PasteMonitor {
    private static var token: Any?

    static func install(_ model: AppModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "v" else { return event }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return event }
            MainActor.assumeIsolated { model.handlePasteboard() }
            return nil
        }
    }
}
