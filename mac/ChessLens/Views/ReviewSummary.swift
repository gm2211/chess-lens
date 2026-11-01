import SwiftUI
import Charts
import ChessCore

/// Top of the annotated game once a review has run: a foldable summary (AI lesson and a card per side),
/// the eval graph and the critical-moments line with "Explain all".
struct ReviewSummarySection: View {
    @Environment(AppModel.self) private var app
    @AppStorage("reviewSummaryCollapsed") private var collapsed = false

    var body: some View {
        let review = app.review
        let s = review.summary(game: app.game)
        let moments = review.criticalMoments()
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                        .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 8)
                    SectionLabel("Summary")
                    Spacer(minLength: 6)
                    if collapsed {
                        Text(accuracyLine(s)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the summary" : "Hide the summary")
            if !collapsed {
                if !review.running { SummaryHero() }
                let phases = review.phaseSummary(game: app.game)
                // Side by side while both cards fit, stacked when the panel is narrow.
                SideBySideOrStacked { cards(s, phases) }
            }
            HStack(spacing: 8) {
                Text(momentsText(moments.count, running: review.running))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if AIHub.shared.isReady { ExplainAllButton(ids: moments) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder private func cards(_ s: (white: SideSummary, black: SideSummary),
                                    _ phases: [Side: [GamePhase: PhaseStat]]) -> some View {
        SummaryCard(name: "White", dark: false, s: s.white, phases: phases[.white] ?? [:])
        SummaryCard(name: "Black", dark: true, s: s.black, phases: phases[.black] ?? [:])
    }

    private func accuracyLine(_ s: (white: SideSummary, black: SideSummary)) -> String {
        func pct(_ a: Double?) -> String { a.map { "\(Int($0.rounded()))%" } ?? "\u{2013}" }
        return "White \(pct(s.white.accuracy)) \u{00B7} Black \(pct(s.black.accuracy))"
    }

    private func momentsText(_ n: Int, running: Bool) -> String {
        if n == 0 { return running ? "Collecting critical moments\u{2026}" : "No critical moments found. Clean game." }
        return "\(n) critical moment\(n == 1 ? "" : "s"), annotated in the moves below."
    }
}

/// The lesson's exercises, shown after the last move.
struct ReviewExercises: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if case .done(let g, _)? = app.review.lesson.state, !g.exercises.isEmpty {
            ExercisesSection(exercises: g.exercises).padding(.horizontal, 14).padding(.vertical, 12)
        }
    }
}

/// "12." / "12\u{2026}" plus the SAN of the move leading to `id`.
@MainActor func moveLabel(_ game: Game, _ id: Int) -> String {
    guard game.nodes.indices.contains(id) else { return "" }
    let n = game.nodes[id]
    guard let p = n.parent.map({ game.nodes[$0].position }) else { return "Start" }
    return "\(p.fullmove)\(p.turn == .white ? "." : "\u{2026}") \(n.san)"
}

/// Small caps label over a section of the lesson card.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
    }
}

/// The AI lesson at the top of the results: concepts and habits first (the payoff), then the story,
/// the turning point and a line per side.
private struct SummaryHero: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ai = app.review.lesson
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                SectionLabel("Lesson from this game")
                Spacer(minLength: 4)
                switch ai.state {
                case .done?, .failed?:
                    Button { ai.generate(game: app.game, review: app.review) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Write the lesson again")
                default: EmptyView()
                }
            }
            content(ai)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private func content(_ ai: AISummary) -> some View {
        switch ai.state {
        case nil:
            if AIHub.shared.isReady {
                Text("The ideas behind the key moments, habits to build and exercises to try.")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                Button { ai.generate(game: app.game, review: app.review) } label: {
                    Label("Write lesson", systemImage: "sparkles")
                }
                .buttonStyle(QuietButtonStyle())
            } else {
                setupHint
            }
        case .loading?:
            AIWaitingLabel(note: ai.switchNote, size: 13)
            VStack(alignment: .leading, spacing: 7) {
                ForEach([0.9, 1.0, 0.75, 0.55], id: \.self) { w in
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(Theme.line).frame(width: g.size.width * w, height: 9)
                    }.frame(height: 9)
                }
            }
            .accessibilityHidden(true)
        case .needsSignIn?:
            setupHint
        case .failed(let m)?:
            AIFailureView(message: m) { ai.generate(game: app.game, review: app.review) }
        case .done(let g, let unverified)?:
            lesson(g, unverified: unverified, ai: ai)
        }
    }

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not signed in to \(AIHub.shared.selected.displayName). Sign in from the AI chip in the header to get a lesson from this game: the ideas behind the key moments, habits to build and exercises.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            if !AIHub.shared.otherReadyProviders.isEmpty { SwitchModelMenu() }
        }
    }

    @ViewBuilder private func lesson(_ g: GameLesson, unverified: [String], ai: AISummary) -> some View {
        if let h = g.headline {
            Text(h).font(.display(21)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
        PlayFullReviewButton(lesson: g, ai: ai)
        if !g.concepts.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("What this game teaches")
                ForEach(Array(g.concepts.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name.prefix(1).uppercased() + c.name.dropFirst())
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        if !c.explanation.isEmpty {
                            Text(c.explanation).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        let title = c.name.prefix(1).uppercased() + c.name.dropFirst()
                        if !c.examples.isEmpty || !c.story.isEmpty {
                            FlowLayout(spacing: 4, lineSpacing: 3) {
                                let steps = c.story.compactMap { st in ai.node(forStep: st).map { LessonPlayer.Step(step: st, nodeID: $0) } }
                                if !steps.isEmpty { PlayLessonButton(title: title, steps: steps) }
                                // In game order, whatever order the model wrote them in.
                                let chips = c.examples.compactMap { e in ai.node(for: e.move).map { (e, $0) } }
                                    .sorted { app.game.nodes[$0.1].ply < app.game.nodes[$1.1].ply }
                                ForEach(Array(chips.enumerated()), id: \.offset) { _, pair in
                                    ExampleChip(id: pair.1, example: pair.0, title: title)
                                }
                            }
                        }
                    }
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
                }
            }
            .padding(.top, 2)
        }
        if !g.lessons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Habits to build")
                ForEach(Array(g.lessons.enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.good)
                        Text(l).font(.system(size: 13)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 2)
        }
        if g.story != nil || g.turningPoint != nil || g.white != nil || g.black != nil {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 2)
        }
        if let st = g.story {
            Text(st).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        if let tp = g.turningPoint, let id = ai.node(for: tp.move) { TurningPointButton(id: id, example: tp) }
        if let w = g.white { sideLine(dark: false, w) }
        if let b = g.black { sideLine(dark: true, b) }
        if !unverified.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle").font(.system(size: 11))
                Text("Some moves unverified").font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.ink3)
            .help("Not found in the game or the engine's lines: \(unverified.joined(separator: ", "))")
        }
    }
}

/// A one-line verdict on one side, after its colour dot.
private func sideLine(dark: Bool, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
        SideDot(dark: dark).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A concept's example move as a small pill: goes to the position after it and illustrates it on the board
/// (caption under the board, arrows and squares on it). Selected while that illustration is showing.
private struct ExampleChip: View {
    @Environment(AppModel.self) private var app
    let id: Int
    let example: GameLesson.Example
    let title: String

    var body: some View {
        let active = app.lessonFocus == LessonFocus(nodeID: id, title: title, example: example)
        Button { app.closeLesson(); app.showExample(example, at: id, title: title) } label: {
            Text(moveLabel(app.game, id)).font(.mono(12, weight: .semibold)).foregroundStyle(active ? Theme.lesson : Theme.ink)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(active ? Theme.lesson.opacity(0.14) : Theme.surface, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(active ? Theme.lesson : Theme.line2, lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .help(example.why ?? "Go to this move")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// "Play lesson": plays the concept's story on the board, narrated (see `LessonPlayer`). "Stop" while it plays.
private struct PlayLessonButton: View {
    @Environment(AppModel.self) private var app
    let title: String
    let steps: [LessonPlayer.Step]

    var body: some View {
        let active = app.lessonPlayer?.title == title
        Button { app.playLesson(title: title, steps: steps) } label: {
            HStack(spacing: 4) {
                Image(systemName: active ? "stop.fill" : "play.fill").font(.system(size: 9, weight: .bold))
                Text(active ? "Stop lesson" : "Play lesson").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(active ? Theme.surface : Theme.lesson)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(active ? Theme.lesson : Theme.lesson.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.lesson.opacity(active ? 1 : 0.55), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!app.canPlayLessons)
        .help(app.canPlayLessons ? "Walk through this idea on the board, narrated (\(steps.count) steps)"
              : "Lessons are paused while you play the engine")
        .accessibilityLabel(active ? "Stop the lesson on \(title)" : "Play the lesson on \(title)")
    }
}

/// "Play full review": the whole lesson as one narrated playlist (intro, every concept in game order, the
/// turning point, the habits to build). See `LessonPlaylist`.
private struct PlayFullReviewButton: View {
    @Environment(AppModel.self) private var app
    let lesson: GameLesson
    let ai: AISummary

    var body: some View {
        let steps = LessonPlaylist.build(lesson: lesson, line: ai.lessonLine).compactMap { ps in
            ai.node(forStep: ps.step).map { LessonPlayer.Step(step: ps.step, nodeID: $0, concept: ps.concept) }
        }
        let active = app.lessonPlayer?.isFullReview == true
        if steps.count > 1 {
            Button { app.playLesson(title: "Full review", steps: steps, fullReview: true) } label: {
                HStack(spacing: 7) {
                    Image(systemName: active ? "stop.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                    Text(active ? "Stop full review" : "Play full review").font(.system(size: 13.5, weight: .semibold))
                    Text("\(steps.count) steps").font(.system(size: 11.5)).opacity(0.8)
                }
                .foregroundStyle(active ? Theme.surface : Theme.lesson)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? Theme.lesson : Theme.lesson.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.lesson.opacity(active ? 1 : 0.6), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!app.canPlayLessons)
            .help(app.canPlayLessons ? "Walk through the whole review on the board, narrated" : "Lessons are paused while you play the engine")
            .accessibilityLabel(active ? "Stop the full review" : "Play the full review")
        }
    }
}

/// "Turning point: 23\u{2026} Nf6": goes there and illustrates it like an example chip.
private struct TurningPointButton: View {
    @Environment(AppModel.self) private var app
    let id: Int
    let example: GameLesson.Example

    var body: some View {
        let active = app.lessonFocus == LessonFocus(nodeID: id, title: "Turning point", example: example)
        Button { app.closeLesson(); app.showExample(example, at: id, title: "Turning point") } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold))
                Text("Turning point: \(moveLabel(app.game, id))").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(active ? Theme.lesson : Theme.accent).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(example.why ?? "Go to the move where the game turned")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct SideDot: View {
    let dark: Bool
    var body: some View {
        Circle().fill(dark ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.96, green: 0.96, blue: 0.94))
            .overlay(Circle().stroke(Theme.ink2, lineWidth: 1.5)).frame(width: 10, height: 10)
    }
}

/// Exercises the lesson proposes, as cards. Drills aren't interactive yet; a card can open its position.
private struct ExercisesSection: View {
    @Environment(AppModel.self) private var app
    let exercises: [GameLesson.Exercise]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Exercises & lessons").font(.display(19))
                Text("COMING SOON").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule())
                Spacer()
            }
            Text("Interactive drills are coming soon. For now, open the position and look for the idea yourself.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(exercises.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "puzzlepiece").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                        Text(e.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 4)
                        if let c = e.concept {
                            Text(c).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.surface, in: Capsule())
                                .overlay(Capsule().stroke(Theme.line2, lineWidth: 1))
                        }
                    }
                    Text(e.task).font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    if let ref = e.fromMove, let id = app.review.lesson.node(for: ref), let pid = app.game.nodes[id].parent {
                        Button { app.goto(pid) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.circle").font(.system(size: 11))
                                Text("Open the position before \(moveLabel(app.game, id))").font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Theme.accent).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
            }
        }
    }
}

struct SummaryCard: View {
    let name: String
    let dark: Bool
    let s: SideSummary
    let phases: [GamePhase: PhaseStat]

    var body: some View {
        let shown = MoveClass.allCases.filter { s.count($0) > 0 }
        let errors = s.inaccuracies + s.mistakes + s.blunders
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(dark ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.96, green: 0.96, blue: 0.94))
                    .overlay(Circle().stroke(Theme.ink2, lineWidth: 1.5)).frame(width: 12, height: 12)
                Text(name.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
            }
            ViewThatFits(in: .horizontal) {
                accuracyRow(s, label: "% accuracy")
                accuracyRow(s, label: "%")
            }
            FlowLayout(spacing: 6, lineSpacing: 3) {
                ForEach(shown, id: \.self) { ClassCount(cls: $0, count: s.count($0)) }
                if errors == 0 && s.moves > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.good)
                        if shown.isEmpty { Text("No errors").font(.system(size: 12.5)).foregroundStyle(Theme.ink3) }
                    }
                    .help("No inaccuracies, mistakes or blunders")
                }
            }
            .frame(minHeight: 18)
            if !phases.isEmpty {
                // Chips wrap to a second line rather than widening the card.
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(GamePhase.allCases, id: \.self) { ph in
                        if let st = phases[ph], st.accuracy != nil { PhaseChip(phase: ph, stat: st) }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
    }
}

/// Two cards in a row when each gets at least `minCard` points, otherwise one above the other.
/// Sized from the width it is offered, so the pair can never be wider than the panel.
private struct SideBySideOrStacked: Layout {
    var minCard: CGFloat = 170
    var gap: CGFloat = 10

    private func sideBySide(_ w: CGFloat) -> Bool { w >= minCard * 2 + gap }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? minCard * 2 + gap
        if sideBySide(w) {
            let cw = (w - gap) / 2
            let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cw, height: nil)).height }.max() ?? 0
            return CGSize(width: w, height: h)
        }
        let hs = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        return CGSize(width: w, height: hs.reduce(0, +) + gap * CGFloat(max(0, hs.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if sideBySide(bounds.width) {
            let cw = (bounds.width - gap) / 2
            let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cw, height: nil)).height }.max() ?? 0
            for (i, v) in subviews.enumerated() {
                v.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (cw + gap), y: bounds.minY), anchor: .topLeading,
                        proposal: ProposedViewSize(width: cw, height: h))
            }
        } else {
            var y = bounds.minY
            for v in subviews {
                let h = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                v.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + gap
            }
        }
    }
}

extension SummaryCard {
    fileprivate func accuracyRow(_ s: SideSummary, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(s.accuracy.map { "\(Int($0.rounded()))" } ?? "\u{2013}").font(.display(36)).lineLimit(1)
            if s.accuracy != nil { Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink3).lineLimit(1) }
        }
    }
}

/// A phase chip's hover label, handed up to the inspector root so no card, scroll view or sibling draws over it.
struct PhaseTip: Equatable { var text: String; var anchor: Anchor<CGRect> }
struct PhaseTipKey: PreferenceKey {
    static let defaultValue: [PhaseTip] = []
    static func reduce(value: inout [PhaseTip], nextValue: () -> [PhaseTip]) { value += nextValue() }
}

extension View {
    /// Draws the phase chips' hover label above everything in this view, clamped inside its bounds.
    func phaseTipHost() -> some View {
        overlayPreferenceValue(PhaseTipKey.self) { tips in
            GeometryReader { geo in
                if let tip = tips.first {
                    let r = geo[tip.anchor]
                    let edge: CGFloat = 6
                    let leftHalf = r.midX < geo.size.width / 2
                    let x0 = leftHalf ? max(edge, r.minX) : edge
                    let w = leftHalf ? geo.size.width - edge - x0 : max(40, min(geo.size.width - edge, r.maxX) - edge)
                    let above = r.minY >= 34
                    Text(tip.text)
                        .font(.system(size: 11)).foregroundStyle(Theme.surface)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: w, alignment: leftHalf ? .leading : .trailing)
                        .offset(x: x0, y: above ? r.minY - 30 : r.maxY + 4)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Opening / middlegame / endgame accuracy: a three-segment marker (which part of the game) + percentage,
/// with a hover label that appears almost at once (the system tooltip takes about a second).
private struct PhaseChip: View {
    let phase: GamePhase
    let stat: PhaseStat
    @State private var hovering = false
    @State private var showTip = false

    var body: some View {
        let acc = Int((stat.accuracy ?? 0).rounded())
        HStack(spacing: 5) {
            PhaseMarker(index: index).foregroundStyle(Theme.ink3)
            Text("\(acc)%").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink2)
        }
        .fixedSize()
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(hovering ? Theme.line2 : Theme.line, lineWidth: 1))
        .anchorPreference(key: PhaseTipKey.self, value: .bounds) { showTip ? [PhaseTip(text: help(acc), anchor: $0)] : [] }
        .onHover { inside in
            hovering = inside
            if inside {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    if hovering { withAnimation(.easeOut(duration: 0.08)) { showTip = true } }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) { showTip = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help(acc))
    }

    private var index: Int {
        switch phase {
        case .opening: 0
        case .middlegame: 1
        case .endgame: 2
        }
    }

    private func help(_ acc: Int) -> String {
        var bits: [String] = []
        for c in [MoveClass.blunder, .mistake, .inaccuracy] {
            let n = c == .blunder ? stat.blunders : c == .mistake ? stat.mistakes : stat.inaccuracies
            if n > 0 { bits.append("\(n) \(c.plural(n))") }
        }
        return "\(phase.name): \(acc)% accuracy over \(stat.moves) move\(stat.moves == 1 ? "" : "s")"
            + (bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))")
    }
}

/// Three short segments with the phase's one solid: opening, middlegame, endgame.
private struct PhaseMarker: View {
    let index: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .frame(width: 6, height: i == index ? 4 : 2)
                    .opacity(i == index ? 1 : 0.35)
            }
        }
        .frame(height: 6)
    }
}

/// The eval graph, pinned above the scrolling summary and move list so clicking it never scrolls it away.
struct PinnedEvalGraph: View {
    @Environment(AppModel.self) private var app
    @AppStorage("evalGraphCollapsed") private var collapsed = false

    var body: some View {
        if app.review.hasResults && !app.hidesEvaluation {
            VStack(spacing: 0) {
                EvalGraph(collapsed: $collapsed).padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
            }
            .background(Theme.surface)
        }
    }
}

private struct EvalGraph: View {
    @Binding var collapsed: Bool
    @Environment(AppModel.self) private var app
    @State private var hoverIndex: Int?

    @State private var showInfo = false

    private struct Point: Identifiable {
        var id: Int; var index: Int; var node: Int; var win: Double; var cls: MoveClass?
        var mover: Side?            // who played the move that led here (nil for the start)
    }

    private var points: [Point] {
        let r = app.review
        var out: [Point] = []
        for (i, id) in r.path.enumerated() {
            guard let e = r.entries[id] else { break }
            let mover = app.game.nodes[id].parent.map { app.game.nodes[$0].position.turn }
            out.append(Point(id: id, index: i, node: id, win: e.eval.whiteWinPercent, cls: e.cls, mover: mover))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if !collapsed {
                chart
                legend
            }
        }
    }

    /// "Winning chances" and the (?) explaining what the line and the dots mean.
    private var header: some View {
        HStack(spacing: 5) {
            Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                    .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 12, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the graph" : "Hide the graph")
            .accessibilityLabel(collapsed ? "Show the evaluation graph" : "Hide the evaluation graph")
            Text("WINNING CHANCES").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.ink3)
            Button { showInfo.toggle() } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("How to read this graph")
            .accessibilityLabel("How to read this graph")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The line is White\u{2019}s winning chances: up is good for White, down is good for Black.")
                    Text("Dots mark moves that lost 5% or more against the engine\u{2019}s best move: coloured by how bad (yellow, orange, red), white or black by who played it.")
                    Text("The line can move without a dot when the engine re-evaluates the position (it sees further), or after a small slip under 5%.")
                }
                .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280).padding(12)
            }
            Spacer(minLength: 0)
        }
    }

    /// "○ Morphy  ● Duke of Brunswick… · yellow inaccuracy · orange mistake · red blunder"
    private var legend: some View {
        FlowLayout(spacing: 8, lineSpacing: 2) {
            playerKey(.white, "White")
            playerKey(.black, "Black")
            ForEach([MoveClass.inaccuracy, .mistake, .blunder], id: \.self) { c in
                HStack(spacing: 3) { Circle().fill(Theme.color(for: c)).frame(width: 6, height: 6); Text(c.name).lineLimit(1) }
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
    }

    private func playerKey(_ side: Side, _ fallback: String) -> some View {
        let full = PGN.meaningful(app.game.header(fallback)) ?? fallback
        return HStack(spacing: 3) {
            Self.marker(cls: nil, side: side)
            Text(Self.shortName(app.game.header(fallback), fallback)).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 130, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .help(full)
    }

    /// A move marker: filled White or Black, ringed in the severity colour (grey without a class).
    static func marker(cls: MoveClass?, side: Side) -> some View {
        let d: CGFloat = cls == .blunder ? 10 : 8.5
        return Circle()
            .fill(side == .white ? Color(red: 0.97, green: 0.97, blue: 0.95) : Color(red: 0.10, green: 0.12, blue: 0.12))
            .overlay(Circle().strokeBorder(cls.map(Theme.color(for:)) ?? Theme.ink3, lineWidth: cls == nil ? 1 : 2.4))
            .frame(width: d, height: d)
    }

    /// A player's name short enough for the legend: "Morphy" for "Paul Morphy", "Carlsen" for "Carlsen, Magnus".
    static func shortName(_ header: String?, _ side: String) -> String {
        guard let n = PGN.meaningful(header) else { return side }
        if let comma = n.firstIndex(of: ",") { return String(n[..<comma]) }
        let words = n.split(separator: " ")
        if words.count <= 3, let last = words.last { return String(last) }
        return n.count > 18 ? String(n.prefix(17)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : n
    }

    private var chart: some View {
        let pts = points
        let path = app.review.path
        let curIndex = path.firstIndex(of: app.currentID)
        return Chart {
            ForEach(pts) { p in
                AreaMark(x: .value("Ply", p.index), yStart: .value("Floor", 0), yEnd: .value("White", p.win))
                    .foregroundStyle(Theme.barW)
                    .interpolationMethod(.monotone)
            }
            ForEach(pts) { p in
                LineMark(x: .value("Ply", p.index), y: .value("White", p.win))
                    .foregroundStyle(Theme.ink3).lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Even", 50)).foregroundStyle(Theme.barLine).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            ForEach(pts.filter { $0.cls != nil }) { p in
                // Filled by the side that moved, ringed by severity: who erred is visible at a glance.
                PointMark(x: .value("Ply", p.index), y: .value("White", p.win))
                    .symbol { Self.marker(cls: p.cls!, side: p.mover ?? .white) }
            }
            if let c = curIndex {
                RuleMark(x: .value("Current", c)).foregroundStyle(Color("hlSel")).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let h = hoverIndex, h != curIndex {
                RuleMark(x: .value("Hover", h)).foregroundStyle(Theme.ink3.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...max(1, path.count - 1))
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartPlotStyle { $0.background(Theme.barB) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc): hoverIndex = index(at: loc, proxy: proxy, geo: geo)
                        case .ended: hoverIndex = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        if let i = index(at: v.location, proxy: proxy, geo: geo), path.indices.contains(i) { app.goto(path[i]) }
                    })
                if let h = hoverIndex, let p = pts.first(where: { $0.index == h }), let x = proxy.position(forX: h) {
                    let origin = geo[proxy.plotFrame!].origin
                    let half = min(118, geo.size.width / 2)
                    tooltip(p).frame(maxWidth: half * 2)
                        .position(x: min(max(origin.x + x, half), geo.size.width - half), y: 32)
                }
            }
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2, lineWidth: 1))
        .accessibilityLabel("Evaluation graph. Click to jump to a move.")
    }

    /// The mover's win-chance cost against the engine's best move, in words: why a bump has (or hasn't) a dot.
    static func verdict(_ review: ReviewModel, game: Game, node: Int) -> String? {
        let n = game.nodes[node]
        guard let pid = n.parent, let move = n.move, let e = review.entries[node], let prev = review.entries[pid]
        else { return nil }
        let mover = game.nodes[pid].position.turn
        let swing = (e.eval.whiteWinPercent - prev.eval.whiteWinPercent) * (mover == .white ? 1 : -1)
        let loss = e.loss ?? 0
        func pct(_ v: Double) -> String { "\u{2212}\(Int(v.rounded()))%" }
        let side = mover == .white ? "White" : "Black"
        let who = PGN.meaningful(game.header(side)).map { "\(side) (\(shortName($0, side)))" } ?? side
        return "\(who) \u{00B7} " + verdictTail(e: e, prev: prev, move: move, swing: swing, loss: loss, pct: pct)
    }

    private static func verdictTail(e: ReviewEntry, prev: ReviewEntry, move: Move, swing: Double, loss: Double,
                                    pct: (Double) -> String) -> String {
        switch e.cls {
        case .brilliant?: return "brilliant move"
        case .great?: return "great move"
        case let c? where c.isError: return "\(pct(loss)) \u{00B7} \(c.name)"
        default: break
        }
        if prev.best == move.uci {
            return abs(swing) >= 3
                ? "+0% \u{00B7} best move; the score moved because the engine saw further"
                : "best move"
        }
        if loss.rounded() >= 1 { return "\(pct(loss)) \u{00B7} small slip, under the 5% inaccuracy line" }
        return "\u{2212}0% \u{00B7} as good as the engine's choice"
    }

    private func index(at loc: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Int? {
        guard let frame = proxy.plotFrame else { return nil }
        let x = loc.x - geo[frame].origin.x
        guard let v: Double = proxy.value(atX: x) else { return nil }
        return max(0, min(app.review.path.count - 1, Int(v.rounded())))
    }

    private func tooltip(_ p: Point) -> some View {
        let n = app.game.nodes[p.node]
        let parent = n.parent.map { app.game.nodes[$0] }
        let label = n.move == nil ? "Start" : "\(parent?.position.fullmove ?? 0)\(parent?.position.turn == .white ? "." : "\u{2026}") \(n.san)"
        let eval = app.review.entries[p.node]?.eval.display ?? ""
        let verdict = Self.verdict(app.review, game: app.game, node: p.node)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                if let c = p.cls { ClassBadge(cls: c, size: 13) }
                Text(eval).foregroundStyle(Theme.ink2)
            }
            .font(.mono(12))
            if let verdict {
                Text(verdict).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2, lineWidth: 1))
            .allowsHitTesting(false)
    }
}
