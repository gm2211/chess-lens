import SwiftUI
import ChessCore

private enum MoveToken {
    case number(String)
    case move(node: Int, depth: Int)
    case open(Int)
    case close(Int)
    case comment(String, depth: Int)
}

private func displayComment(_ raw: String?) -> String? {
    guard var s = raw else { return nil }
    // Hide engine/clock commands such as [%clk 0:03:00] and [%eval 0.3].
    while let r = s.range(of: #"\[%[^\]]*\]"#, options: .regularExpression) { s.removeSubrange(r) }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

private func buildTokens(_ g: Game) -> [MoveToken] {
    var out: [MoveToken] = []

    func emitMove(parent: Int, node: Int, force: Bool, depth: Int) {
        let pos = g.nodes[parent].position
        if pos.turn == .white { out.append(.number("\(pos.fullmove).")) }
        else if force { out.append(.number("\(pos.fullmove)\u{2026}")) }
        out.append(.move(node: node, depth: depth))
        if let c = displayComment(g.nodes[node].comment) { out.append(.comment(c, depth: depth)) }
    }

    func continuation(from start: Int, depth: Int, force: Bool) {
        var cur = start
        var forceNumber = force
        while let first = g.nodes[cur].children.first {
            emitMove(parent: cur, node: first, force: forceNumber, depth: depth)
            let kids = g.nodes[cur].children
            for alt in kids.dropFirst() {
                out.append(.open(depth + 1))
                emitMove(parent: cur, node: alt, force: true, depth: depth + 1)
                continuation(from: alt, depth: depth + 1, force: displayComment(g.nodes[alt].comment) != nil)
                out.append(.close(depth + 1))
            }
            forceNumber = displayComment(g.nodes[first].comment) != nil || kids.count > 1
            cur = first
        }
    }

    if let c = displayComment(g.nodes[0].comment) { out.append(.comment(c, depth: 0)) }
    continuation(from: 0, depth: 0, force: true)
    return out
}

struct MoveListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let tokens = buildTokens(app.game)
        ScrollViewReader { proxy in
            ScrollView {
                FlowLayout(spacing: 1, lineSpacing: 4) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                        tokenView(token)
                    }
                    if app.game.result != "*" {
                        Text(app.game.result)
                            .font(.system(size: 13)).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .fullWidthInFlow()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 12)
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
    private func tokenView(_ t: MoveToken) -> some View {
        switch t {
        case .number(let s):
            Text(s).font(.mono(12.5)).foregroundStyle(Theme.ink3).padding(.leading, 4).padding(.trailing, 1)
        case .move(let id, let depth):
            MoveButton(id: id, depth: depth).id("mv\(id)")
        case .open(let d):
            Text("(").font(.mono(13)).foregroundStyle(Theme.ink3).padding(.leading, d > 1 ? 2 : 4)
        case .close:
            Text(")").font(.mono(13)).foregroundStyle(Theme.ink3).padding(.trailing, 2)
        case .comment(let c, let d):
            Text(c)
                .font(.system(size: d == 0 ? 13 : 12.5).italic())
                .foregroundStyle(Theme.ink2)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fullWidthInFlow()
        }
    }
}

private struct MoveButton: View {
    @Environment(AppModel.self) private var app
    let id: Int
    let depth: Int
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
            .padding(.horizontal, 6).padding(.vertical, 2)
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
