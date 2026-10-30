import SwiftUI
import Charts
import ChessCore

struct ReviewPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var review = app.review
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEPTH").font(.system(size: 11, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
                    Picker("Depth", selection: $review.selectedDepth) {
                        ForEach(ReviewDepth.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 190)
                    .disabled(review.running)
                }
                Button("Review game") { app.startReview() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(review.running || !app.engine.isAvailable)
                Spacer()
            }
            .padding(14)

            if review.running {
                HStack(spacing: 12) {
                    ProgressView(value: Double(review.done), total: Double(max(review.path.count, 1)))
                        .progressViewStyle(.linear).tint(Theme.accent)
                    Text("\(review.done) / \(review.path.count)")
                        .font(.mono(12.5)).foregroundStyle(Theme.ink3).frame(minWidth: 64, alignment: .trailing)
                    Button("Cancel") { app.cancelReview() }.buttonStyle(QuietButtonStyle())
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SummaryCard(name: "White", dark: false, s: s.white)
                SummaryCard(name: "Black", dark: true, s: s.black)
            }
            .padding(.horizontal, 14).padding(.top, 14)

            EvalGraph().padding(.horizontal, 14)

            Text("Critical moments").font(.display(19)).padding(.horizontal, 14)
            let moments = review.criticalMoments()
            if moments.isEmpty {
                Text(review.running ? "Collecting\u{2026}" : "No inaccuracies found. Clean game.")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink3).padding(.horizontal, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(moments, id: \.self) { id in
                        MomentRow(id: id)
                        Divider()
                    }
                }.padding(.horizontal, 14)
            }
        }
    }
}

private struct SummaryCard: View {
    let name: String
    let dark: Bool
    let s: SideSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(dark ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.96, green: 0.96, blue: 0.94))
                    .overlay(Circle().stroke(Theme.ink2, lineWidth: 1.5)).frame(width: 12, height: 12)
                Text(name.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(s.accuracy.map { "\(Int($0.rounded()))" } ?? "\u{2013}").font(.display(36))
                if s.accuracy != nil { Text("% accuracy").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink3) }
            }
            HStack(spacing: 10) {
                Text("\(s.inaccuracies) ?!").foregroundStyle(Theme.inacc)
                Text("\(s.mistakes) ?").foregroundStyle(Theme.mist)
                Text("\(s.blunders) ??").foregroundStyle(Theme.blund)
            }.font(.mono(12.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
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
        let best = parent.flatMap { p in app.review.entries[p.id]?.best.flatMap { b in p.position.move(fromUCI: b).map { p.position.san($0) } } }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
                app.goto(id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 8)
                    Text("\(parent?.position.fullmove ?? 0)\(parent?.position.turn == .white ? "." : "\u{2026}") \(node.san)").font(.mono(14, weight: .semibold))
                    if let c = entry?.cls { Text(c.rawValue).font(.mono(13, weight: .bold)).foregroundStyle(Theme.color(for: c)) }
                    Spacer()
                    Text("\(best.map { "best \($0)" } ?? "") \u{00B7} \u{2212}\(Int((entry?.loss ?? 0).rounded()))%")
                        .font(.mono(12.5)).foregroundStyle(Theme.ink3)
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
        let label = n.move == nil ? "Start" : "\(parent?.position.fullmove ?? 0)\(parent?.position.turn == .white ? "." : "\u{2026}") \(n.san)\(p.cls?.rawValue ?? "")"
        let eval = app.review.entries[p.node]?.eval.display ?? ""
        return Text("\(label)  \(eval)")
            .font(.mono(12)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2, lineWidth: 1))
            .allowsHitTesting(false)
    }
}
