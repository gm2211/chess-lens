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

            strengthField

            if setup.strength == .full {
                field("Engine thinks for") {
                    Picker("Engine thinks for", selection: $setup.thinkMillis) {
                        ForEach(PlaySetup.thinkChoices, id: \.self) { Text(Self.thinkLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
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

    // MARK: Strength

    /// The slider's last stop, one step past Stockfish's highest Elo, means full strength.
    private static let fullStop = Double(PlayStrength.eloRange.upperBound + 100)

    private var sliderValue: Binding<Double> {
        Binding(
            get: { setup.strength.elo.map(Double.init) ?? Self.fullStop },
            set: { v in
                setup.strength = v > Double(PlayStrength.eloRange.upperBound) ? .full : PlayStrength(elo: Int((v / 10).rounded()) * 10)
            })
    }

    private var strengthField: some View {
        let s = setup.strength
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Strength").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink2)
                Spacer()
                Text(s.elo.map { "Elo \($0)" } ?? "Full strength").font(.mono(12.5, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Slider(value: sliderValue, in: Double(PlayStrength.eloRange.lowerBound)...Self.fullStop, step: 10)
                .labelsHidden()
                .accessibilityLabel("Engine strength")
                .accessibilityValue(s.elo.map { "Elo \($0)" } ?? "Full strength")
            HStack(spacing: 4) {
                ForEach(PlayStrength.presets, id: \.label) { p in
                    Button { setup.strength = p.strength } label: {
                        Text(p.label).font(.system(size: 11.5, weight: s == p.strength ? .semibold : .regular))
                            .foregroundStyle(s == p.strength ? Theme.accentInk : Theme.ink3)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(s == p.strength ? Theme.accentSoft : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(p.strength.elo.map { "Elo \($0)" } ?? "No strength limit")
                }
            }
            derived(s)
        }
    }

    /// What the Elo means for how Stockfish plays (see `PlayStrength`).
    private func derived(_ s: PlayStrength) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let level = s.skillLevel, let depth = s.pickDepth, let ms = s.limitedMoveTime {
                fact("Skill level", String(format: "%.1f of 20", level))
                fact("Looks ahead", "\(depth) half-move\(depth == 1 ? "" : "s") before picking")
                fact("Max think time", Self.thinkLabel(ms) + " per move")
            } else {
                fact("Skill level", "20 of 20 (no limit)")
                fact("Looks ahead", "As deep as the think time allows")
            }
            Text(s.note).font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink2).monospacedDigit()
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink2)
            content()
        }
    }

    /// "0.25 s", "0.5 s", "1 s", "3.5 s".
    static func thinkLabel(_ ms: Int) -> String {
        let s = Double(ms) / 1000
        return (s == s.rounded() ? String(Int(s)) : String(format: "%g", s)) + " s"
    }
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
