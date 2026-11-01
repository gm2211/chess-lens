import SwiftUI
import ChessCore

/// One visual row of the move table, which shows a single line (root → `AppModel.lineTip`): a numbered
/// pair, a source comment under its move, the branch chips at a fork, or a review note on a critical moment.
private enum MoveRow {
    case pair(number: Int, white: Int?, black: Int?)
    case comment(after: Int, text: String)
    case chips(LineFork)
    case annotation(Int)

    /// Stable across rebuilds (unlike the row's offset, which shifts when review notes are inserted),
    /// so SwiftUI keeps each row's identity and doesn't rebuild the rows below an insertion.
    var id: String {
        switch self {
        case .pair(let n, let w, let b): "p\(n).\(w ?? -1).\(b ?? -1)"
        case .comment(let after, _): "b\(after)"
        case .chips(let f): "c\(f.parent)"
        case .annotation(let id): "a\(id)"
        }
    }
}

func displayComment(_ raw: String?) -> String? {
    guard var s = raw else { return nil }
    // Hide engine/clock commands such as [%clk 0:03:00] and [%eval 0.3].
    while let r = s.range(of: #"\[%[^\]]*\]"#, options: .regularExpression) { s.removeSubrange(r) }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

/// Whether the game carries analysis from its source: comments, NAGs or `[%eval]` values.
func gameHasSourceAnalysis(_ g: Game) -> Bool {
    g.nodes.contains { n in
        !n.nags.isEmpty || displayComment(n.comment) != nil || n.comment.flatMap(PGN.evalAnnotation) != nil
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

/// Node of the shown `line` each critical moment's note hangs under: the moment itself, or for a moment
/// off the line, the line's move at the point where the moment's branch leaves it.
private func momentAnchors(_ g: Game, line: [Int], moments: [Int]) -> [Int: [Int]] {
    let index = Dictionary(uniqueKeysWithValues: line.enumerated().map { ($1, $0) })
    var out: [Int: [Int]] = [:]
    for id in moments where g.nodes.indices.contains(id) {
        var a = id
        while index[a] == nil, let p = g.nodes[a].parent {
            if let i = index[p] { a = line.indices.contains(i + 1) ? line[i + 1] : p; break }
            a = p
        }
        if index[a] != nil, a != 0 { out[a, default: []].append(id) }
    }
    return out
}

private func buildRows(_ g: Game, line: [Int], showSource: Bool, anchors: [Int: [Int]]) -> [MoveRow] {
    var rows: [MoveRow] = []
    var pending: (number: Int, white: Int?, black: Int?)?

    // A pair's branch chips (white's first) and moment notes follow the pair, so "10. Nxb5 cxb5" stays on one line.
    func flush() {
        if let p = pending {
            rows.append(.pair(number: p.number, white: p.white, black: p.black))
            let moves = [p.white, p.black].compactMap { $0 }
            for id in moves {
                if let parent = g.nodes[id].parent, g.nodes[parent].children.count > 1 {
                    rows.append(.chips(LineFork(parent: parent, node: id, siblings: g.nodes[parent].children)))
                }
            }
            for id in moves { rows += (anchors[id] ?? []).map { .annotation($0) } }
        }
        pending = nil
    }

    if showSource, let c = displayComment(g.nodes[0].comment) { rows.append(.comment(after: 0, text: c)) }
    for (cur, next) in zip(line, line.dropFirst()) {
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
        if showSource, let comment = displayComment(g.nodes[next].comment) {
            flush()
            rows.append(.comment(after: next, text: comment))
        }
    }
    flush()
    return rows
}

/// "12. Nf3" / "12… Nf6" for the move leading to `id`.
private func numberedSAN(_ g: Game, _ id: Int) -> String {
    let n = g.nodes[id]
    guard let p = n.parent else { return n.san }
    let pos = g.nodes[p].position
    return pos.turn == .white ? "\(pos.fullmove). \(n.san)" : "\(pos.fullmove)\u{2026} \(n.san)"
}

/// The first few moves of the branch starting at `id`, for a chip's tooltip.
private func branchPreview(_ g: Game, from id: Int, plies: Int = 8) -> String {
    let ids = Array(g.mainline(from: id).prefix(plies))
    var parts: [String] = []
    for (i, n) in ids.enumerated() {
        let p = g.nodes[n].parent.map { g.nodes[$0].position }
        if i == 0 || p?.turn == .white { parts.append(numberedSAN(g, n)) } else { parts.append(g.nodes[n].san) }
    }
    let more = g.mainline(from: id).count > plies ? " \u{2026}" : ""
    return parts.joined(separator: " ") + more
}

/// The annotated game: review summary and eval graph on top (after a review), then the move table for the
/// shown line with branch chips at every fork, critical-moment notes under their moves, the result (on the
/// game's own line) or a way back to it, and the lesson's exercises.
///
/// A plain VStack, not a LazyVStack: the review summary is a tall first child, so a lazy stack's size
/// estimate for the unrealized rows swung by thousands of points as rows came and went, and every
/// scroll to the current move re-measured and jumped (the sidebar flickered on each click). A game's
/// table is at most a few hundred light rows, so laying it all out is cheap and gives exact geometry.
/// The body doesn't read `currentID` (see `FollowCurrentMove`), so moving doesn't rebuild the rows; it reads
/// `lineTip`, which changes only when the user switches to another line.
struct MoveListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let reviewed = app.review.hasResults && !app.hidesEvaluation
        let line = app.displayLine
        let anchors = reviewed ? momentAnchors(app.game, line: line, moments: app.review.criticalMoments()) : [:]
        let rows = buildRows(app.game, line: line, showSource: app.showSourceAnalysis, anchors: anchors)
        let offMain = app.isOffMainline
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if reviewed {
                        ReviewSummarySection()
                        Divider().padding(.bottom, 6)
                    }
                    ForEach(rows, id: \.id) { row in rowView(row) }
                    if offMain {
                        Button { app.backToGameLine() } label: {
                            Label("Back to game line", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(QuietButtonStyle())
                        .help("Return to where this line left the game and show the game's moves again")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    } else if app.game.result != "*" {
                        Text(app.game.result)
                            .font(.mono(13)).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    if reviewed && !app.review.running { ReviewExercises() }
                }
                .padding(.vertical, 6)
            }
            .background { FollowCurrentMove(proxy: proxy) }
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
    private func rowView(_ row: MoveRow) -> some View {
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
        case .comment(_, let text):
            Text(text).font(.system(size: 12.5).italic()).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line2).frame(width: 2) }
                .padding(.leading, 44).padding(.trailing, 12).padding(.vertical, 4)
        case .chips(let fork):
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(fork.siblings, id: \.self) { sib in
                    BranchChip(id: sib, selected: sib == fork.node)
                }
            }
            .padding(.leading, 52).padding(.trailing, 12).padding(.top, 3).padding(.bottom, 6)
        case .annotation(let id):
            MomentAnnotation(id: id)
        }
    }

    @ViewBuilder
    private func cell(_ id: Int?) -> some View {
        Group {
            if let id { MoveButton(id: id).id("mv\(id)") }
            else { Text("\u{2026}").font(.mono(14)).foregroundStyle(Theme.ink3).padding(.horizontal, 8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One alternative at a fork: "19. Qb7". The one on the shown line is selected; the game's own move is tagged
/// "game". Clicking switches the shown line to that branch.
private struct BranchChip: View {
    @Environment(AppModel.self) private var app
    let id: Int
    let selected: Bool
    @State private var hover = false

    var body: some View {
        if app.game.nodes.indices.contains(id) { content } else { EmptyView() }
    }

    @ViewBuilder private var content: some View {
        let g = app.game
        let isGame = g.isOnMainline(id)
        let isFirst = g.nodes[id].parent.map { g.nodes[$0].children.first == id } ?? true
        Button { app.goto(id) } label: {
            HStack(spacing: 5) {
                Text(numberedSAN(g, id)).font(.mono(12, weight: .medium))
                if isGame {
                    Text("game").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selected ? Theme.accent.opacity(0.85) : Theme.ink3)
                }
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.ink2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(selected ? Theme.accentSoft : (hover ? Theme.surface2 : Theme.surface),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.line2, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(branchPreview(g, from: id))
        .contextMenu {
            if !isFirst { Button("Make Main Line") { app.promote(id) } }
            Button("Delete Branch", role: .destructive) { app.deleteFrom(id) }
        }
        .accessibilityLabel("\(numberedSAN(g, id))\(isGame ? ", game move" : "")\(selected ? ", shown" : "")")
    }
}

/// Keeps the current move in view. Only this view reads `currentID`, so a move re-renders it and the
/// move buttons, not the whole list. With no anchor, `scrollTo` scrolls the least amount needed and not
/// at all when the move is already visible: clicking a move (or a chip in the summary) doesn't yank the list.
private struct FollowCurrentMove: View {
    @Environment(AppModel.self) private var app
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: app.currentID) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("mv\(id)") }
            }
    }
}

private struct MoveButton: View {
    @Environment(AppModel.self) private var app
    let id: Int
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
            .font(.mono(14, weight: .medium))
            .foregroundStyle(current ? Theme.accentInk : Theme.ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
