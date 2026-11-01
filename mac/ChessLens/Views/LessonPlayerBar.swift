import SwiftUI
import ChessCore

/// The lesson player under the board, in the caption's place: the concept, the step being narrated, the line being
/// acted out, step dots and the transport (previous, play/pause, next, narration on/off, close).
struct LessonPlayerBar: View {
    @Environment(AppModel.self) private var app
    let player: LessonPlayer

    var body: some View {
        let step = player.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "graduationcap.fill").font(.system(size: 10.5, weight: .semibold))
                Text(player.isFullReview ? "FULL REVIEW" : player.title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(0.7).lineLimit(1)
                if player.isFullReview, let concept = step.concept {
                    Text(concept).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.lesson.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                        .id(concept)
                        .transition(.opacity)
                }
                Text(step.step.isStart ? "Start" : moveLabel(app.game, step.nodeID))
                    .font(.mono(11, weight: .semibold)).foregroundStyle(Theme.ink3)
                Spacer(minLength: 6)
                Text(player.isFullReview ? "Step \(player.index + 1)/\(player.steps.count)" : "\(player.index + 1) / \(player.steps.count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
                closeButton
            }
            .foregroundStyle(Theme.lesson)

            Text(step.step.say)
                .font(.system(size: 14.5)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .id(player.index)
                .transition(.opacity.combined(with: .offset(y: 3)))

            if !player.lineSAN.isEmpty { lineRow }

            HStack(spacing: 4) {
                transport("backward.fill", "Previous step (\u{2190})", enabled: player.canGoBack || player.linePly > 0) { player.previous() }
                transport(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "Pause (Space)" : "Play (Space)",
                          enabled: true, prominent: true) { player.togglePlay() }
                transport("forward.fill", "Next step (\u{2192})", enabled: player.canGoForward) { player.next() }
                dots.padding(.leading, 8)
                Spacer(minLength: 6)
                transport(player.narrate ? "speaker.wave.2.fill" : "speaker.slash.fill",
                          player.narrate ? "Mute the narration" : "Read the lesson aloud", enabled: true) {
                    player.narrate.toggle()
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: 520 + 36, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.lesson.opacity(0.45), lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.lesson).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
        .animation(.easeOut(duration: 0.2), value: player.index)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(player.isFullReview ? "Full review" : "Lesson: \(player.title)"), \(step.concept.map { $0 + ", " } ?? "")step \(player.index + 1) of \(player.steps.count)")
    }

    /// "Instead: 12. O-O-O Rd8 13. Rxd7", the moves already shown in the lesson colour.
    private var lineRow: some View {
        let sans = player.lineSAN
        let pos = app.game.nodes[player.current.nodeID].position
        var number = pos.fullmove, white = pos.turn == .white
        var parts: [(String, Bool)] = []
        for (i, s) in sans.enumerated() {
            let label = white ? "\(number). \(s)" : (i == 0 ? "\(number)\u{2026} \(s)" : s)
            parts.append((label, i < player.linePly))
            if !white { number += 1 }
            white.toggle()
        }
        return HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                Text(p.0).font(.mono(12, weight: p.1 ? .semibold : .regular))
                    .foregroundStyle(p.1 ? Theme.lesson : Theme.ink3)
            }
        }
        .lineLimit(1)
        .help("A line shown on the board for this step; it is not added to the game")
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(player.steps.indices, id: \.self) { i in
                Button { player.go(to: i) } label: {
                    Capsule().fill(i == player.index ? Theme.lesson : i < player.index ? Theme.lesson.opacity(0.45) : Theme.line2)
                        .frame(width: i == player.index ? 16 : 7, height: 7)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help("Step \(i + 1)")
            }
        }
        .animation(.easeOut(duration: 0.2), value: player.index)
    }

    private var closeButton: some View {
        Button { app.closeLesson() } label: {
            Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ink3)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close the lesson (Esc)")
        .accessibilityLabel("Close the lesson")
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
