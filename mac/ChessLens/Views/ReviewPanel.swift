import SwiftUI
import Charts
import ChessCore

struct ReviewPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var review = app.review
        VStack(spacing: 0) {
            HStack(spacing: 8) {
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
                    .help("Review the game with the engine")
                    .disabled(review.running || !app.engine.isAvailable)
                Spacer(minLength: 8)
                AIProviderChip(name: AIHub.shared.selected.displayName, ready: AIHub.shared.isReady) {
                    AIProvidersView().padding(12)
                }
                .task { await AIHub.shared.refresh(AIHub.shared.selected) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            if review.running {
                HStack(spacing: 12) {
                    ProgressView(value: Double(review.done), total: Double(max(review.path.count, 1)))
                        .progressViewStyle(.linear).tint(Theme.accent)
                    Text("\(review.done) / \(review.path.count)")
                        .font(.mono(12.5)).foregroundStyle(Theme.ink3).frame(minWidth: 64, alignment: .trailing)
                    Button("Cancel") { app.cancelReview() }.buttonStyle(QuietButtonStyle())
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }

            Divider()
            if review.hasResults {
                ScrollView { ReviewResults().padding(.bottom, 14) }
            } else {
                VStack(spacing: 6) {
                    Text(review.running ? "Reviewing\u{2026}" : "Find the turning points").font(.display(20)).foregroundStyle(Theme.ink)
                    Text(review.running
                         ? "Analysing every position at depth \(review.depth.rawValue)."
                         : "The engine plays through every move of the line you are viewing, charts the evaluation and flags inaccuracies, mistakes and blunders.")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.surface)
    }
}

private struct ReviewResults: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let review = app.review
        let s = review.summary(game: app.game)
        let phases = review.phaseSummary(game: app.game)
        let moments = review.criticalMoments()
        VStack(alignment: .leading, spacing: 14) {
            if !review.running {
                SummaryHero().padding(.horizontal, 14).padding(.top, 14)
            }
            HStack(alignment: .top, spacing: 10) {
                SummaryCard(name: "White", dark: false, s: s.white, phases: phases[.white] ?? [:])
                SummaryCard(name: "Black", dark: true, s: s.black, phases: phases[.black] ?? [:])
            }
            .padding(.horizontal, 14).padding(.top, review.running ? 14 : 0)

            EvalGraph().padding(.horizontal, 14)

            HStack(spacing: 8) {
                Text("Critical moments").font(.display(19))
                Spacer()
                ExplainAllButton(ids: moments)
            }
            .padding(.horizontal, 14)
            if moments.isEmpty {
                Text(review.running ? "Collecting\u{2026}" : "No critical moments found. Clean game.")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink3).padding(.horizontal, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(moments, id: \.self) { id in
                        MomentRow(id: id)
                        Divider()
                    }
                }.padding(.horizontal, 14)
            }
            if case .done(let g, _)? = review.lesson.state, !g.exercises.isEmpty {
                ExercisesSection(exercises: g.exercises).padding(.horizontal, 14)
            }
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing your lesson\u{2026}").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            }
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
            HStack(spacing: 8) {
                Text(m).font(.system(size: 12.5)).foregroundStyle(Theme.blund).lineLimit(2).truncationMode(.tail)
                Spacer(minLength: 4)
                Button("Retry") { ai.generate(game: app.game, review: app.review) }.buttonStyle(QuietButtonStyle())
            }
        case .done(let g, let unverified)?:
            lesson(g, unverified: unverified, ai: ai)
        }
    }

    private var setupHint: some View {
        Text("Set up AI in the header to get a lesson from this game: the ideas behind the key moments, habits to build and exercises.")
            .font(.system(size: 12.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func lesson(_ g: GameLesson, unverified: [String], ai: AISummary) -> some View {
        if let h = g.headline {
            Text(h).font(.display(21)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
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
                        if !c.moves.isEmpty {
                            FlowLayout(spacing: 4, lineSpacing: 3) {
                                ForEach(c.moves, id: \.self) { ref in
                                    if let id = ai.node(for: ref) { MoveRefButton(id: id) }
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
        if let tp = g.turningPoint, let id = ai.node(for: tp) {
            Button { app.goto(id) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold))
                    Text("Turning point: \(moveLabel(app.game, id))").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to the move where the game turned")
        }
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

/// A move reference as a small pill that jumps to the move.
private struct MoveRefButton: View {
    @Environment(AppModel.self) private var app
    let id: Int
    var prefix: String = ""

    var body: some View {
        Button { app.goto(id) } label: {
            Text(prefix + moveLabel(app.game, id)).font(.mono(12, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Go to this move")
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

private struct SummaryCard: View {
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
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(s.accuracy.map { "\(Int($0.rounded()))" } ?? "\u{2013}").font(.display(36))
                if s.accuracy != nil { Text("% accuracy").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink3) }
            }
            HStack(spacing: 6) {
                ForEach(shown, id: \.self) { ClassCount(cls: $0, count: s.count($0)) }
                if errors == 0 && s.moves > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.good)
                        if shown.isEmpty { Text("No errors").font(.system(size: 12.5)).foregroundStyle(Theme.ink3) }
                    }
                    .help("No inaccuracies, mistakes or blunders")
                }
            }
            .lineLimit(1)
            .frame(height: 18)
            if !phases.isEmpty {
                HStack(spacing: 4) {
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

/// Opening / middlegame / endgame accuracy as icon + number.
private struct PhaseChip: View {
    let phase: GamePhase
    let stat: PhaseStat

    var body: some View {
        let acc = Int((stat.accuracy ?? 0).rounded())
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.ink3)
            Text("\(acc)").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
        .help(help(acc))
    }

    private var icon: String {
        switch phase {
        case .opening: "book.closed"
        case .middlegame: "bolt"
        case .endgame: "flag"
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

private struct MomentRow: View {
    @Environment(AppModel.self) private var app
    let id: Int
    @State private var expanded = false

    var body: some View {
        if app.game.nodes.indices.contains(id) { content } else { EmptyView() }
    }

    @ViewBuilder private var content: some View {
        let node = app.game.nodes[id]
        let entry = app.review.entries[id]
        let parent = node.parent.map { app.game.nodes[$0] }
        let concept: String? = if case .done(let l, _)? = app.review.commentary.states[id] { l.concept } else { nil }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
                app.goto(id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 8)
                        Text(moveLabel(app.game, id)).font(.mono(14, weight: .semibold))
                        if let c = entry?.cls { ClassBadge(cls: c).help(c.name.prefix(1).uppercased() + c.name.dropFirst()) } else { TurnBadge() }
                        Spacer(minLength: 8)
                        if let prev = parent.flatMap({ app.review.entries[$0.id] }), let e = entry {
                            Text("\(prev.eval.display) \u{2192} \(e.eval.display)")
                                .font(.mono(12)).foregroundStyle(Theme.ink3).lineLimit(1)
                        }
                    }
                    if let concept, !expanded {
                        Text(concept.prefix(1).uppercased() + concept.dropFirst())
                            .font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).padding(.leading, 16)
                    }
                }
                .padding(.vertical, 9).padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { MomentDetail(id: id).padding(.leading, 18).padding(.bottom, 10) }
        }
    }
}

private struct EvalGraph: View {
    @Environment(AppModel.self) private var app
    @State private var hoverIndex: Int?

    private struct Point: Identifiable { var id: Int; var index: Int; var node: Int; var win: Double; var cls: MoveClass? }

    private var points: [Point] {
        let r = app.review
        var out: [Point] = []
        for (i, id) in r.path.enumerated() {
            guard let e = r.entries[id] else { break }
            out.append(Point(id: id, index: i, node: id, win: e.eval.whiteWinPercent, cls: e.cls))
        }
        return out
    }

    var body: some View {
        let pts = points
        let path = app.review.path
        let curIndex = path.firstIndex(of: app.currentID)
        Chart {
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
                PointMark(x: .value("Ply", p.index), y: .value("White", p.win))
                    .foregroundStyle(Theme.color(for: p.cls!))
                    .symbolSize(p.cls == .blunder ? 46 : 32)
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
                    tooltip(p).position(x: min(max(origin.x + x, 70), geo.size.width - 70), y: 16)
                }
            }
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line2, lineWidth: 1))
        .accessibilityLabel("Evaluation graph. Click to jump to a move.")
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
        return HStack(spacing: 5) {
            Text(label)
            if let c = p.cls { ClassBadge(cls: c, size: 13) }
            Text(eval).foregroundStyle(Theme.ink2)
        }
            .font(.mono(12)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2, lineWidth: 1))
            .allowsHitTesting(false)
    }
}
