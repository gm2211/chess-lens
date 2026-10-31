import SwiftUI
import ChessCore

// MARK: - Setup

struct PlaySetupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var setup = PlaySetup.saved(side: .white)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Play against Stockfish").font(.display(24)).foregroundStyle(Theme.ink)
                Text("Continue from this position, with \(app.position.turn == .white ? "White" : "Black") to move. Your moves are added to the game.")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("You play") {
                Picker("You play", selection: $setup.userSide) {
                    Text("White").tag(Side.white)
                    Text("Black").tag(Side.black)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            field("Strength") {
                Picker("Strength", selection: $setup.strength) {
                    ForEach(PlayStrength.allCases) { Text($0.detail).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }

            field("Engine thinks for") {
                Picker("Engine thinks for", selection: $setup.thinkMillis) {
                    ForEach(PlaySetup.thinkChoices, id: \.self) { Text(Self.thinkLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            VStack(alignment: .leading, spacing: 3) {
                Toggle("Hide evaluation while playing", isOn: $setup.hideEvaluation)
                    .font(.system(size: 13, weight: .semibold))
                Text("Hides the evaluation bar, engine lines and arrows until the game ends.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            }

            if !app.engine.isAvailable { Notice(kind: .error, text: "The engine is not available in this build.") }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Start") { dismiss(); app.beginPlay(setup) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!app.engine.isAvailable)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Theme.surface)
        .onAppear { setup.userSide = app.position.turn }
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink2)
            content()
        }
    }

    static func thinkLabel(_ ms: Int) -> String { ms < 1000 ? "0.5 s" : "\(ms / 1000) s" }
}

// MARK: - Banner

struct PlayBanner: View {
    @Environment(AppModel.self) private var app
    let session: PlaySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.headline).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink3)
            HStack(spacing: 8) {
                status
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) { buttons }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: 520 + 36, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        if let failure = session.failure {
            Text(failure).font(.system(size: 14)).foregroundStyle(Theme.blund)
        } else if let result = session.resultText {
            Text(result).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
        } else if session.isPaused {
            Text("Paused \u{2014} resume from here to keep playing").font(.system(size: 14)).foregroundStyle(Theme.ink2)
        } else if session.thinking {
            ProgressView().controlSize(.small)
            Text("Stockfish is thinking\u{2026}").font(.system(size: 14)).foregroundStyle(Theme.ink2)
        } else {
            Text("Your move").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder private var buttons: some View {
        if session.ending != nil {
            Button("Review this game") { app.reviewPlayedGame() }.buttonStyle(PrimaryButtonStyle())
            takeBack
            Button("Done") { app.endPlay() }.buttonStyle(QuietButtonStyle())
        } else if session.failure != nil {
            Button("Stop") { app.endPlay() }.buttonStyle(QuietButtonStyle())
        } else {
            if session.isPaused {
                Button("Resume from here") { session.resume() }.buttonStyle(PrimaryButtonStyle())
            }
            takeBack
            Button("Resign") { session.resign() }.buttonStyle(QuietButtonStyle())
                .help("Resign the game")
            Button("Stop") { app.endPlay() }.buttonStyle(QuietButtonStyle())
                .help("Stop playing and keep the moves")
        }
    }

    private var takeBack: some View {
        Button("Take back") { session.takeBack() }
            .buttonStyle(QuietButtonStyle())
            .disabled(!session.canTakeBack)
            .help("Undo your last move and the reply")
    }
}

/// Stands in for the engine and review panels while the evaluation is hidden.
struct PlayHiddenNotice: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Evaluation hidden").font(.display(20)).foregroundStyle(Theme.ink)
            Text("It comes back when the game ends or you stop playing.")
                .font(.system(size: 13)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
