import SwiftUI
import ChessCore

extension GameLesson.Beat.Kind {
    /// The dot colour of a beat in the story timeline and on the beat card.
    var color: Color {
        switch self {
        case .setup: Theme.great
        case .slip: Theme.inacc
        case .turning: Theme.blund
        case .punish: Theme.mist
        case .finish: Theme.good
        case .idea: Theme.lesson
        }
    }
}

/// The guided review under the board, in the caption's place: "Beat 2 of 5 \u{00B7} The slip", the headline, then
/// the find-the-better-move question or the explanation and rule, and the transport (previous, play, next, read
/// aloud, close). See `BeatWalkthrough`.
struct BeatCard: View {
    @Environment(AppModel.self) private var app
    let walkthrough: BeatWalkthrough

    var body: some View {
        let w = walkthrough
        let step = w.current
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(step.beat.kind.color).frame(width: 8, height: 8)
                Text("Beat \(w.index + 1) of \(w.steps.count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
                Text("\u{00B7}").foregroundStyle(Theme.ink3)
                Text(step.beat.title).font(.system(size: 11, weight: .semibold)).tracking(0.3).foregroundStyle(Theme.lesson)
                    .lineLimit(1)
                Text(beatMove(step)).font(.mono(11, weight: .semibold)).foregroundStyle(Theme.ink3)
                Spacer(minLength: 6)
                closeButton
            }

            Text(step.beat.headline)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            content(w, step)
                .id("\(w.index)-\(phaseKey(w.phase))")
                .transition(.opacity.combined(with: .offset(y: 3)))

            HStack(spacing: 4) {
                transport("backward.fill", "Previous beat (\u{2190})", enabled: w.canGoBack) { w.previous() }
                transport(w.isPlaying ? "pause.fill" : "play.fill",
                          w.isPlaying ? "Pause (Space)" : "Play: read every beat aloud and move on (Space)",
                          enabled: true, prominent: true) { w.togglePlay() }
                transport("forward.fill", "Next beat (\u{2192})", enabled: w.canGoForward) { w.next() }
                dots(w).padding(.leading, 8)
                Spacer(minLength: 6)
                transport(w.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2", w.isSpeaking ? "Stop reading" : "Read this beat aloud",
                          enabled: true) { w.toggleSpeech() }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: 520 + 36, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.lesson.opacity(0.45), lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(step.beat.kind.color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
        .animation(.easeOut(duration: 0.2), value: w.index)
        .animation(.easeOut(duration: 0.2), value: phaseKey(w.phase))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided review, beat \(w.index + 1) of \(w.steps.count): \(step.beat.title)")
    }

    // MARK: Content

    @ViewBuilder private func content(_ w: BeatWalkthrough, _ step: BeatWalkthrough.Step) -> some View {
        switch w.phase {
        case .asking:
            question(step)
            HStack(spacing: 6) {
                pill("Show me", "eye", prominent: false) { w.reveal() }
                pill("Skip", "forward", prominent: false) { w.canGoForward ? w.next() : app.closeLesson() }
            }
        case .judging:
            question(step)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking your move\u{2026}").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            }
        case .verdict(let v, _, _):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: v.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(v.isCorrect ? Theme.good : Theme.mist)
                Text(BetterMove.text(v)).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if v.isCorrect {
                explanation(step)
                pill("See the game move", "eye", prominent: false) { w.reveal() }
            } else {
                HStack(spacing: 6) {
                    pill("Try again", "arrow.uturn.backward", prominent: true) { w.clearAttempt() }
                    pill("Show me", "eye", prominent: false) { w.reveal() }
                    pill("Skip", "forward", prominent: false) { w.canGoForward ? w.next() : app.closeLesson() }
                }
            }
        case .shown(let onAnswer):
            answer(w, onAnswer: onAnswer)
            explanation(step)
        case .explained:
            explanation(step)
        }
    }

    private func question(_ step: BeatWalkthrough.Step) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.lesson)
            Text(step.quiz.map { BetterMove.prompt(side: $0.side) } ?? "")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.lesson)
            Text("Play it on the board").font(.system(size: 12)).foregroundStyle(Theme.ink3)
        }
    }

    /// "The engine's choice: 9\u{2026}Nbd7. The game went 9\u{2026}b5, and 10. Nxb5 punished it."
    private func answer(_ w: BeatWalkthrough, onAnswer: Bool) -> some View {
        var parts: [String] = []
        if let b = w.bestLabel { parts.append("The engine's choice: \(b).") }
        if let p = w.playedLabel {
            parts.append(w.refutationLabel.map { "The game went \(p), and \($0) punished it." } ?? "The game went \(p).")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lightbulb.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.good)
            Text(parts.joined(separator: " ")).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func explanation(_ step: BeatWalkthrough.Step) -> some View {
        if let e = step.beat.explain {
            Text(e).font(.system(size: 13.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        if let r = step.beat.rule {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.good)
                Text(r).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.good.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func beatMove(_ step: BeatWalkthrough.Step) -> String {
        step.beat.ply == 0 || step.beat.at.lowercased() == "start" ? "Start" : moveLabel(app.game, step.nodeID)
    }

    private func phaseKey(_ p: BeatWalkthrough.Phase) -> String {
        switch p {
        case .asking: "ask"
        case .judging: "judge"
        case .verdict(let v, let m, _): "verdict-\(m.uci)-\(v.isCorrect)"
        case .shown(let a): "shown-\(a)"
        case .explained: "explained"
        }
    }

    // MARK: Controls

    private func dots(_ w: BeatWalkthrough) -> some View {
        HStack(spacing: 5) {
            ForEach(w.steps.indices, id: \.self) { i in
                Button { w.go(to: i) } label: {
                    Capsule().fill(i == w.index ? w.steps[i].beat.kind.color : i < w.index ? Theme.lesson.opacity(0.45) : Theme.line2)
                        .frame(width: i == w.index ? 16 : 7, height: 7)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help("Beat \(i + 1): \(w.steps[i].beat.title)")
            }
        }
    }

    private func pill(_ title: String, _ symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Theme.surface : Theme.lesson)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(prominent ? Theme.lesson : Theme.lesson.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.lesson.opacity(prominent ? 1 : 0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button { app.closeLesson() } label: {
            Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ink3)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close the walkthrough (Esc)")
        .accessibilityLabel("Close the walkthrough")
    }

    private func transport(_ symbol: String, _ help: String, enabled: Bool, prominent: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(prominent ? Theme.surface : Theme.ink2)
                .frame(width: prominent ? 30 : 26, height: 26)
                .background(prominent ? Theme.lesson : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}
