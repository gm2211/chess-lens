import SwiftUI
import ChessCore

/// The closed state of "Ask AI": a field-like row under the move list. Clicking it opens the drawer.
struct AskBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let reason = app.askUnavailableReason
        Button { app.openAsk() } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12))
                Text("Ask AI about this move\u{2026}").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text("\u{21E7}\u{2318}A").font(.mono(11.5, weight: .regular)).foregroundStyle(Theme.ink3)
            }
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .opacity(reason == nil ? 1 : 0.5)
        .help(reason ?? "Ask the AI a question about this position or move (\u{21E7}\u{2318}A)")
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// The open chat: the position in question, the conversation, suggested questions and a text field.
/// Navigating to another move keeps the conversation; the header follows the board.
struct AskDrawer: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    /// The inspector's height; the drawer never grows past it minus the room the content above needs.
    let available: Double
    @AppStorage("ask.drawerHeight") private var storedHeight = AskDrawer.defaultHeight
    /// Height when the current drag began; nil when not dragging.
    @State private var dragStart: Double?
    @State private var hovering = false

    static let defaultHeight = 300.0
    /// Header + input + about two lines of conversation.
    static let minHeight = 190.0
    /// What the inspector keeps for its header, engine strip, a little move list and the footer.
    static let reservedAbove = 300.0

    static func clamp(_ h: Double, available: Double) -> Double {
        max(minHeight, min(h, available - reservedAbove))
    }

    private var height: Double { Self.clamp(storedHeight, available: available) }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(height: height)
        .background(Theme.surface)
        .onAppear { focused = true }
        .onExitCommand { app.ask.close() }
    }

    /// A thin grabber on the top edge: drag to resize, double-click for the default height.
    private var grabber: some View {
        ZStack {
            Capsule().fill(Theme.ink3.opacity(hovering || dragStart != nil ? 0.9 : 0.45)).frame(width: 36, height: 3)
        }
        .frame(maxWidth: .infinity).frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = dragStart ?? height
                    dragStart = start
                    // Dragging up (negative y) makes the drawer taller.
                    storedHeight = Self.clamp(start - v.translation.height, available: available)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { storedHeight = Self.defaultHeight }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .help("Drag to resize; double-click to reset")
        .accessibilityLabel("Resize Ask AI")
    }

    // MARK: Header

    private var header: some View {
        let node = app.node
        let before = node.parent.map { app.game.nodes[$0].position }
        let label = AskPrompt.contextLabel(position: node.position, before: before, move: node.move)
        return HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            VStack(alignment: .leading, spacing: 0) {
                Text("Ask AI").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink3)
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { app.ask.clear() } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(Theme.ink2)
                .help("Clear the conversation")
                .disabled(app.ask.messages.isEmpty && !app.ask.isThinking)
            Button { app.ask.close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(Theme.ink2)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // MARK: Transcript

    private var transcript: some View {
        let ask = app.ask
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if ask.messages.isEmpty && !ask.isThinking {
                        Text("Ask about this position or a move: why a move was played, what the plan is, what to watch for. Stockfish checks the ideas.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(ask.messages) { MessageRow(message: $0) }
                    if ask.isThinking { thinking(partial: ask.partial) }
                    switch ask.status {
                    case .needsSignIn:
                        notice("No AI provider is set up. Use the AI chip at the top of this panel to sign in or choose one.", retry: false)
                    case .failed(let m):
                        notice(m, retry: true)
                    default: EmptyView()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onChange(of: ask.messages.count) { _, _ in proxy.scrollTo("end") }
            .onChange(of: ask.partial) { _, _ in proxy.scrollTo("end") }
            .onChange(of: ask.status) { _, _ in proxy.scrollTo("end") }
        }
    }

    @ViewBuilder private func thinking(partial: String?) -> some View {
        if let partial, !partial.isEmpty {
            AnswerBubble(text: partial)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking\u{2026}").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func notice(_ text: String, retry: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.mist)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            if retry {
                Spacer(minLength: 4)
                Button("Try Again") { app.ask.retry(game: app.game, review: app.review, node: app.currentID) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        @Bindable var ask = app.ask
        let reason = app.askUnavailableReason
        let text = ask.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            if !ask.isThinking && text.isEmpty && reason == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AskAI.starters(game: app.game, review: app.review, id: app.currentID), id: \.self) { q in
                            Button { app.sendAsk(q) } label: {
                                Text(q).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink2)
                                    .padding(.horizontal, 9).frame(height: 24)
                                    .background(Theme.surface2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $ask.draft)
                        .font(.system(size: 13)).scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(height: 44)
                        .disabled(reason != nil)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }       // Shift-Return: new line
                            send()
                            return .handled
                        }
                    if ask.draft.isEmpty {
                        Text(reason ?? "Ask a question\u{2026}  (Return sends)")
                            .font(.system(size: 13)).foregroundStyle(Theme.ink3)
                            .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                if ask.isThinking {
                    Button { app.ask.cancel() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.ink2).help("Stop")
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(text.isEmpty || reason != nil ? Theme.ink3 : Theme.accent)
                        .disabled(text.isEmpty || reason != nil)
                        .help("Send (Return)")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func send() {
        guard !app.ask.isThinking else { return }
        app.sendAsk(app.ask.draft)
    }
}

private struct MessageRow: View {
    let message: AskMessage

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            }
        case .assistant(let unverified):
            VStack(alignment: .leading, spacing: 4) {
                AnswerBubble(text: message.text)
                if !unverified.isEmpty {
                    Label("Some moves unverified", systemImage: "questionmark.circle")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                        .help("These moves were not in the game or the engine's results, so they may be wrong: "
                              + unverified.joined(separator: ", "))
                }
            }
        case .note:
            Text(message.text).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct AnswerBubble: View {
    let text: String

    var body: some View {
        let styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        HStack {
            Text(styled)
                .font(.system(size: 13)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 24)
        }
    }
}
