import SwiftUI
import ChessCore

// MARK: - Inspector

/// The side panel: review controls, the live engine strip, then the annotated game, with "Ask AI" below it.
/// The game's title and subtitle are in the window title, so the panel doesn't repeat them.
struct InspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            Divider()
            if !app.hidesEvaluation {
                EngineStrip()
                Divider()
            }
            MoveListView()
                .frame(minHeight: 100)
            Divider()
            if app.ask.isOpen {
                AskDrawer()
            } else {
                AskBar()
            }
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
        .background(Theme.surface)
    }
}

/// Review depth, Review, the source-analysis toggle and the AI provider; review progress below while it runs.
/// While a play session hides the evaluation, the review controls give way to a note.
private struct PanelHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var review = app.review
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if app.hidesEvaluation {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Evaluation hidden").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("It comes back when the game ends or you stop playing.")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    sourceToggle
                } else {
                    Menu {
                        Picker("Depth", selection: $review.selectedDepth) {
                            ForEach(ReviewDepth.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: {
                        Label("\(review.selectedDepth.rawValue)", systemImage: "gauge.with.dots.needle.50percent")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                    .help("Review depth: \(review.selectedDepth.label)")
                    .disabled(review.running)
                    Button { app.startReview() } label: { Label("Review", systemImage: "play.fill").frame(height: 28) }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Review the game with the engine: chart the evaluation and annotate the critical moments")
                        .disabled(review.running || !app.engine.isAvailable)
                    Spacer(minLength: 8)
                    sourceToggle
                    AIProviderChip(name: AIHub.shared.selected.displayName, ready: AIHub.shared.isReady) {
                        AIProvidersView().padding(12)
                    }
                    .task { await AIHub.shared.refresh(AIHub.shared.selected) }
                }
            }
            if review.running {
                HStack(spacing: 12) {
                    ProgressView(value: Double(review.done), total: Double(max(review.path.count, 1)))
                        .progressViewStyle(.linear).tint(Theme.accent)
                    Text("\(review.done) / \(review.path.count)")
                        .font(.mono(12.5)).foregroundStyle(Theme.ink3).frame(minWidth: 64, alignment: .trailing)
                    Button("Cancel") { app.cancelReview() }.buttonStyle(QuietButtonStyle())
                }
                .help("Reviewing at depth \(review.depth.rawValue)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var sourceToggle: some View {
        if gameHasSourceAnalysis(app.game) {
            @Bindable var app = app
            Toggle(isOn: $app.showSourceAnalysis) { Image(systemName: "text.bubble") }
                .toggleStyle(.button).buttonStyle(QuietButtonStyle())
                .help(app.showSourceAnalysis ? "Hide the source's comments, evals and annotations" : "Show the source's comments, evals and annotations")
                .accessibilityLabel("Show source analysis")
        }
    }
}
