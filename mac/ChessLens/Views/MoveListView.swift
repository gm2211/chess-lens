import SwiftUI
import ChessCore

private enum MoveToken {
    case number(String)
    case move(node: Int, depth: Int)
    case open(Int)
    case close(Int)
}

/// One visual row of the move table: a numbered main-line pair, or an inset block of
/// comments and side variations hanging off the move above it.
private enum MoveRow {
    case pair(number: Int, white: Int?, black: Int?)
    case block(comment: String?, variations: [[MoveToken]])
}

private func displayComment(_ raw: String?) -> String? {
    guard var s = raw else { return nil }
    // Hide engine/clock commands such as [%clk 0:03:00] and [%eval 0.3].
    while let r = s.range(of: #"\[%[^\]]*\]"#, options: .regularExpression) { s.removeSubrange(r) }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
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

private func buildRows(_ g: Game) -> [MoveRow] {
    var rows: [MoveRow] = []
    var pending: (number: Int, white: Int?, black: Int?)?

    func flush() {
        if let p = pending { rows.append(.pair(number: p.number, white: p.white, black: p.black)) }
        pending = nil
    }

    if let c = displayComment(g.nodes[0].comment) { rows.append(.block(comment: c, variations: [])) }
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
        let comment = displayComment(g.nodes[next].comment)
        let alts = g.nodes[cur].children.dropFirst().map { variationTokens(g, parent: cur, node: $0) }
        if comment != nil || !alts.isEmpty {
            flush()
            rows.append(.block(comment: comment, variations: alts))
        }
        cur = next
    }
    flush()
    return rows
}

struct MoveListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let rows = buildRows(app.game)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        rowView(row, index: i)
                    }
                    if app.game.result != "*" {
                        Text(app.game.result)
                            .font(.mono(13)).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
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
        let cls = app.review.entries[id]?.cls
        Button { app.goto(id) } label: {
            HStack(spacing: 0) {
                Text(node.san)
                if let cls { Text(cls.rawValue).foregroundStyle(current ? Theme.accentInk : Theme.color(for: cls)).fontWeight(.bold) }
                else if !node.nags.isEmpty {
                    Text(node.nags.map { PGN.nagText($0) }.joined()).foregroundStyle(current ? Theme.accentInk : Theme.ink2)
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
            Button("Delete From Here", role: .destructive) { app.deleteFrom(id) }
        }
        .accessibilityLabel(node.san)
    }
}
