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

/// The guided review under the board, in the caption's place: "Beat 2 of 5 \u{00B7} The slip", the beat's headline,
/// then the scene's current line as a subtitle with its progress, the find-the-better-move question when the scene
/// stops to ask, the rule once the scene is over, and the transport (previous, play, next, replay, voice, close).
/// See `BeatWalkthrough`.
struct BeatCard: View {
    @Environment(AppModel.self) private var app
    let walkthrough: BeatWalkthrough

    var body: some View {
        let w = walkthrough
        let step = w.current
        VStack(alignment: .leading, spacing: 6) {
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
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink3)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)

            subtitle(w)
                .id("\(w.index)-\(w.sceneIndex)-\(phaseKey(w.phase))")
                .transition(.opacity.combined(with: .offset(y: 3)))

            sceneProgress(w)

            controls(w, step)

            HStack(spacing: 4) {
                transport("backward.fill", "Previous beat (\u{2190})", enabled: w.canGoBack) { w.previous() }
                transport(w.isPlaying || w.isRunning ? "pause.fill" : "play.fill",
                          w.isPlaying || w.isRunning ? "Pause (Space)" : "Play every beat hands-free (Space)",
                          enabled: true, prominent: true) { w.togglePlay() }
                transport("forward.fill", "Next beat (\u{2192})", enabled: w.canGoForward) { w.next() }
                dots(w).padding(.leading, 8)
                Spacer(minLength: 6)
                transport("arrow.counterclockwise", "Replay this scene", enabled: !step.scene.isEmpty) { w.replayScene() }
                transport(w.narrate ? "speaker.wave.2.fill" : "speaker.slash", w.narrate ? "Mute the narrator" : "Read the scene aloud",
                          enabled: true) { w.narrate.toggle() }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: 520 + 36, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.lesson.opacity(0.45), lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(step.beat.kind.color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
        .animation(.easeOut(duration: 0.2), value: w.index)
        .animation(.easeOut(duration: 0.2), value: w.sceneIndex)
        .animation(.easeOut(duration: 0.2), value: phaseKey(w.phase))
        .animation(.easeOut(duration: 0.2), value: w.finished)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided review, beat \(w.index + 1) of \(w.steps.count): \(step.beat.title)")
    }

    // MARK: Content

    /// The line being spoken, like a video's subtitle; the verdict on a try in its place.
    @ViewBuilder private func subtitle(_ w: BeatWalkthrough) -> some View {
        switch w.phase {
        case .verdict(let v, _, _):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: v.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(v.isCorrect ? Theme.good : Theme.mist)
                Text(BetterMove.text(v)).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            Text(w.sceneStep?.say ?? "")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One thin segment per scene step: done, current, to come.
    private func sceneProgress(_ w: BeatWalkthrough) -> some View {
        HStack(spacing: 3) {
            ForEach(w.current.scene.indices, id: \.self) { i in
                Capsule()
                    .fill(i < w.sceneIndex || (i == w.sceneIndex && w.finished) ? Theme.lesson.opacity(0.55)
                          : i == w.sceneIndex ? Theme.lesson : Theme.line2)
                    .frame(height: 2.5)
            }
        }
        .frame(maxWidth: 220)
        .accessibilityLabel("Scene step \(w.sceneIndex + 1) of \(w.current.scene.count)")
    }

    @ViewBuilder private func controls(_ w: BeatWalkthrough, _ step: BeatWalkthrough.Step) -> some View {
        switch w.phase {
        case .asking:
            question(step)
            HStack(spacing: 6) {
                pill("Skip the question", "forward", prominent: false) { w.continueScene() }
            }
        case .judging:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking your move\u{2026}").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            }
        case .verdict(let v, _, _):
            HStack(spacing: 6) {
                if v.isCorrect {
                    pill("Continue", "play.fill", prominent: true) { w.continueScene() }
                } else {
                    pill("Try again", "arrow.uturn.backward", prominent: true) { w.clearAttempt() }
                    pill("Show me", "eye", prominent: false) { w.continueScene() }
                }
            }
        case .scene:
            if w.finished, let r = step.beat.rule { rule(r) }
        }
    }

    private func question(_ step: BeatWalkthrough.Step) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.lesson)
            Text(step.quiz.map { BetterMove.prompt(side: $0.side) } ?? "")
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.lesson)
            Text("Play it on the board").font(.system(size: 12)).foregroundStyle(Theme.ink3)
        }
    }

    private func rule(_ r: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.good)
            Text(r).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.good.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }

    private func beatMove(_ step: BeatWalkthrough.Step) -> String {
        step.beat.ply == 0 || step.beat.at.lowercased() == "start" ? "Start" : moveLabel(app.game, step.nodeID)
    }

    private func phaseKey(_ p: BeatWalkthrough.Phase) -> String {
        switch p {
        case .asking: "ask"
        case .judging: "judge"
        case .verdict(let v, let m, _): "verdict-\(m.uci)-\(v.isCorrect)"
        case .scene: "scene"
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
