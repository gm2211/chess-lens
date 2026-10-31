import SwiftUI
import ChessCore

private enum MoveToken {
    case number(String)
    case move(node: Int, depth: Int)
    case open(Int)
    case close(Int)
}

/// One visual row of the move table: a numbered main-line pair, an inset block of
/// comments and side variations hanging off the move above it, or a review note on a critical moment.
private enum MoveRow {
    case pair(number: Int, white: Int?, black: Int?)
    case block(comment: String?, variations: [[MoveToken]])
    case annotation(Int)
}

func displayComment(_ raw: String?) -> String? {
    guard var s = raw else { return nil }
    // Hide engine/clock commands such as [%clk 0:03:00] and [%eval 0.3].
    while let r = s.range(of: #"\[%[^\]]*\]"#, options: .regularExpression) { s.removeSubrange(r) }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

/// Whether the game carries analysis from its source: comments, side variations or `[%eval]` values.
func gameHasSourceAnalysis(_ g: Game) -> Bool {
    g.nodes.contains { n in
        n.children.count > 1 || displayComment(n.comment) != nil || n.comment.flatMap(PGN.evalAnnotation) != nil
    }
}

/// "+0.23", "-1.50", "#3", "#-2" for the small eval chip.
private func evalChipText(_ e: Eval) -> String {
    switch e {
    case .cp(let c): return c == 0 ? "0.00" : String(format: "%+.2f", Double(c) / 100)
    case .mate(let m): return "#\(m)"
    case .checkmate(let w): return w == .white ? "1-0" : "0-1"
    }
}

/// Inline tokens for a side variation starting with `node` (a child of `parent`).
private func variationTokens(_ g: Game, parent: Int, node: Int) -> [MoveToken] {
    var out: [MoveToken] = []

    func emitMove(parent: Int, node: Int, force: Bool, depth: Int) {
        let pos = g.nodes[parent].position
        if pos.turn == .white { out.append(.number("\(pos.fullmove).")) }
        else if force { out.append(.number("\(pos.fullmove)\u{2026}")) }
        out.append(.move(node: node, depth: depth))
    }

    func continuation(from start: Int, depth: Int) {
        var cur = start
        var force = false
        while let first = g.nodes[cur].children.first {
            emitMove(parent: cur, node: first, force: force, depth: depth)
            let kids = g.nodes[cur].children
            for alt in kids.dropFirst() {
                out.append(.open(depth + 1))
                emitMove(parent: cur, node: alt, force: true, depth: depth + 1)
                continuation(from: alt, depth: depth + 1)
                out.append(.close(depth + 1))
            }
            force = kids.count > 1
            cur = first
        }
    }

    emitMove(parent: parent, node: node, force: true, depth: 1)
    continuation(from: node, depth: 1)
    return out
}

/// Main-line node each critical moment's note hangs under: the moment itself, or for a moment inside a
/// side variation, the main-line move that variation replaces.
private func momentAnchors(_ g: Game, moments: [Int]) -> [Int: [Int]] {
    var main = Set<Int>()
    var cur = 0
    while let next = g.nodes[cur].children.first { main.insert(next); cur = next }
    var out: [Int: [Int]] = [:]
    for id in moments where g.nodes.indices.contains(id) {
        var a = id
        while !main.contains(a), let p = g.nodes[a].parent {
            if p == 0 || main.contains(p) { a = g.nodes[p].children.first ?? a; break }
            a = p
        }
        if main.contains(a) { out[a, default: []].append(id) }
    }
    return out
}

private func buildRows(_ g: Game, showSource: Bool, anchors: [Int: [Int]]) -> [MoveRow] {
    var rows: [MoveRow] = []
    var pending: (number: Int, white: Int?, black: Int?)?

    // A pair's moment notes follow the pair, so "10. Nxb5 cxb5" stays on one line.
    func flush() {
        if let p = pending {
            rows.append(.pair(number: p.number, white: p.white, black: p.black))
            for id in [p.white, p.black].compactMap({ $0 }) { rows += (anchors[id] ?? []).map { .annotation($0) } }
        }
        pending = nil
    }

    if showSource, let c = displayComment(g.nodes[0].comment) { rows.append(.block(comment: c, variations: [])) }
    var cur = 0
    while let next = g.nodes[cur].children.first {
        let pos = g.nodes[cur].position
        if pos.turn == .white {
            flush()
            pending = (pos.fullmove, next, nil)
        } else if var p = pending, p.black == nil, p.number == pos.fullmove {
            p.black = next; pending = p
            flush()
        } else {
            flush()
            pending = (pos.fullmove, nil, next)
            flush()
        }
        let comment = showSource ? displayComment(g.nodes[next].comment) : nil
        let alts = !showSource ? [] : g.nodes[cur].children.dropFirst().map { variationTokens(g, parent: cur, node: $0) }
        if comment != nil || !alts.isEmpty {
            flush()
            rows.append(.block(comment: comment, variations: alts))
        }
        cur = next
    }
    flush()
    return rows
}

/// The annotated game: review summary and eval graph on top (after a review), then the move table with
/// critical-moment notes under their moves, the result, and the lesson's exercises.
struct MoveListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let reviewed = app.review.hasResults && !app.hidesEvaluation
        let anchors = reviewed ? momentAnchors(app.game, moments: app.review.criticalMoments()) : [:]
        let rows = buildRows(app.game, showSource: app.showSourceAnalysis, anchors: anchors)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if reviewed {
                        ReviewSummarySection()
                        Divider().padding(.bottom, 6)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        rowView(row, index: i)
                    }
                    if app.game.result != "*" {
                        Text(app.game.result)
                            .font(.mono(13)).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    if reviewed && !app.review.running { ReviewExercises() }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: app.currentID) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("mv\(id)", anchor: .center) }
            }
        }
        .background(Theme.surface)
        .overlay {
            if app.game.nodes.count == 1 {
                VStack(spacing: 4) {
                    Text("No moves yet").font(.display(20)).foregroundStyle(Theme.ink)
                    Text("Play a move on the board, or import a game.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MoveRow, index: Int) -> some View {
        switch row {
        case .pair(let number, let white, let black):
            HStack(spacing: 4) {
                Text("\(number)")
                    .font(.mono(12.5, weight: .regular)).foregroundStyle(Theme.ink3)
                    .frame(width: 30, alignment: .trailing)
                    .padding(.trailing, 6)
                cell(white)
                cell(black)
            }
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(number % 2 == 0 ? Theme.surface2.opacity(0.45) : .clear)
        case .block(let comment, let variations):
            VStack(alignment: .leading, spacing: 4) {
                if let comment {
                    Text(comment).font(.system(size: 12.5).italic()).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(variations.enumerated()), id: \.offset) { _, tokens in
                    FlowLayout(spacing: 1, lineSpacing: 2) {
                        ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in tokenView(t) }
                    }
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.line2).frame(width: 2) }
            .padding(.leading, 44).padding(.trailing, 12).padding(.vertical, 4)
        case .annotation(let id):
            MomentAnnotation(id: id)
        }
    }

    @ViewBuilder
    private func cell(_ id: Int?) -> some View {
        Group {
            if let id { MoveButton(id: id, depth: 0, fill: true).id("mv\(id)") }
            else { Text("\u{2026}").font(.mono(14)).foregroundStyle(Theme.ink3).padding(.horizontal, 8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tokenView(_ t: MoveToken) -> some View {
        switch t {
        case .number(let s):
            Text(s).font(.mono(12, weight: .regular)).foregroundStyle(Theme.ink3).padding(.leading, 3)
        case .move(let id, let depth):
            MoveButton(id: id, depth: depth, fill: false).id("mv\(id)")
        case .open:
            Text("(").font(.mono(12.5)).foregroundStyle(Theme.ink3).padding(.leading, 3)
        case .close:
            Text(")").font(.mono(12.5)).foregroundStyle(Theme.ink3).padding(.trailing, 2)
        }
    }
}

private struct MoveButton: View {
    @Environment(AppModel.self) private var app
    let id: Int
    let depth: Int
    let fill: Bool
    @State private var hover = false

    var body: some View {
        if app.game.nodes.indices.contains(id) { content } else { EmptyView() }
    }

    @ViewBuilder private var content: some View {
        let node = app.game.nodes[id]
        let current = id == app.currentID
        let cls = app.hidesEvaluation ? nil : app.review.entries[id]?.cls
        let eval = app.showSourceAnalysis && !app.hidesEvaluation ? node.comment.flatMap(PGN.evalAnnotation) : nil
        let nags = app.showSourceAnalysis ? node.nags : []
        Button { app.goto(id) } label: {
            HStack(spacing: 0) {
                Text(node.san)
                if let cls { Text(cls.rawValue).foregroundStyle(current ? Theme.accentInk : Theme.color(for: cls)).fontWeight(.bold) }
                else if !nags.isEmpty {
                    Text(nags.map { PGN.nagText($0) }.joined()).foregroundStyle(current ? Theme.accentInk : Theme.ink2)
                }
                if let eval {
                    Text(evalChipText(eval)).font(.mono(11, weight: .regular))
                        .foregroundStyle(current ? Theme.accentInk.opacity(0.75) : Theme.ink3).padding(.leading, 6)
                }
            }
            .font(.mono(depth > 0 ? 12.5 : 14, weight: .medium))
            .foregroundStyle(current ? Theme.accentInk : (depth > 0 ? Theme.ink2 : Theme.ink))
            .padding(.horizontal, fill ? 8 : 4).padding(.vertical, fill ? 4 : 1)
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            .background(current ? Theme.accent : (hover ? Theme.surface2 : .clear), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            if let p = node.parent, app.game.nodes[p].children.first != id {
                Button("Make Main Line") { app.promote(id) }
            }
            Button("Continue Against Engine From Here") { app.requestPlay(from: id) }
            Button("Ask AI About This Move\u{2026}") { app.askAbout(id) }
                .disabled(!app.canAskAI)
            Divider()
            Button("Delete From Here", role: .destructive) { app.deleteFrom(id) }
        }
        .accessibilityLabel(node.san)
    }
}
