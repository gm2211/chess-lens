import Foundation

/// One node of the move tree. Node 0 is the root (the starting position, no move).
public struct GameNode: Sendable, Identifiable, Equatable {
    public var id: Int
    public var parent: Int?
    public var move: Move?
    public var san: String
    public var position: Position           // position AFTER `move`
    public var comment: String?
    public var nags: [Int]
    public var children: [Int]              // children[0] is the main continuation
    /// Whether the user played this move themselves (on the board, from the engine, in a play session) as
    /// opposed to it coming from the imported game or setup. "Clear explored lines" removes only these.
    public var explored: Bool

    public init(id: Int, parent: Int?, move: Move?, san: String, position: Position, comment: String? = nil, nags: [Int] = [], children: [Int] = [], explored: Bool = false) {
        self.id = id; self.parent = parent; self.move = move; self.san = san
        self.position = position; self.comment = comment; self.nags = nags; self.children = children
        self.explored = explored
    }

    /// Ply number of the move leading to this node, derived from the position (1 = White's first move).
    public var ply: Int {
        guard move != nil else { return 0 }
        return (position.fullmove - 1) * 2 + (position.turn == .white ? 0 : 1)
    }
}

public struct Game: Sendable, Equatable {
    public var headers: [(key: String, value: String)]
    public var nodes: [GameNode]
    public var result: String

    public static func == (a: Game, b: Game) -> Bool {
        a.nodes == b.nodes && a.result == b.result
            && a.headers.map { $0.key + "\u{0}" + $0.value } == b.headers.map { $0.key + "\u{0}" + $0.value }
    }

    public init(startPosition: Position = .start, headers: [(key: String, value: String)] = []) {
        self.headers = headers
        self.nodes = [GameNode(id: 0, parent: nil, move: nil, san: "", position: startPosition)]
        self.result = "*"
        if startPosition.fen != Position.startFEN {
            setHeader("SetUp", "1"); setHeader("FEN", startPosition.fen)
        }
    }

    public var startPosition: Position { nodes[0].position }
    public subscript(id: Int) -> GameNode { nodes[id] }

    public func header(_ key: String) -> String? { headers.first { $0.key == key }?.value }
    public mutating func setHeader(_ key: String, _ value: String) {
        if let i = headers.firstIndex(where: { $0.key == key }) { headers[i].value = value }
        else { headers.append((key, value)) }
    }

    /// Adds `move` after `node`, reusing an existing identical child (which keeps its own `explored` flag).
    /// Importers leave `explored` false; interactive play passes true. Returns the child id.
    @discardableResult
    public mutating func addMove(_ move: Move, after node: Int, explored: Bool = false) throws -> Int {
        if let existing = nodes[node].children.first(where: { nodes[$0].move == move }) { return existing }
        let pos = nodes[node].position
        let san = pos.san(move)
        let next = try pos.applying(move)
        let id = nodes.count
        nodes.append(GameNode(id: id, parent: node, move: move, san: san, position: next, explored: explored))
        nodes[node].children.append(id)
        return id
    }

    /// Node ids from the root to `node` inclusive; empty when `node` is not in this game (a stale id).
    public func path(to node: Int) -> [Int] {
        var out: [Int] = []
        var cur: Int? = node
        while let c = cur, nodes.indices.contains(c) { out.append(c); cur = nodes[c].parent }
        guard cur == nil else { return [] }
        return out.reversed()
    }

    /// Ids along the main line starting at `node` (inclusive), following first children.
    public func mainline(from node: Int = 0) -> [Int] {
        var out = [node]
        var cur = node
        while let next = nodes[cur].children.first { out.append(next); cur = next }
        return out
    }

    /// The line to display/analyse for `node`: root → node, then main continuation.
    public func fullLine(through node: Int) -> [Int] {
        let p = path(to: node)
        return p + mainline(from: node).dropFirst()
    }

    /// Makes the variation containing `node` the main line at its branching point.
    public mutating func promote(_ node: Int) {
        guard let p = nodes[node].parent, let i = nodes[p].children.firstIndex(of: node), i > 0 else { return }
        nodes[p].children.remove(at: i)
        nodes[p].children.insert(node, at: 0)
    }

    /// Removes `node` and its descendants from the tree (rebuilding ids).
    public mutating func delete(_ node: Int) {
        guard let p = nodes[node].parent else { return }
        nodes[p].children.removeAll { $0 == node }
        compact()
    }

    /// How many moves `clearExplored()` would remove: every explored move and whatever follows it.
    public var exploredCount: Int {
        var n = 0
        var stack = [0]
        while let c = stack.popLast() {
            for k in nodes[c].children {
                if nodes[k].explored { n += subtreeSize(k) } else { stack.append(k) }
            }
        }
        return n
    }

    private func subtreeSize(_ node: Int) -> Int {
        var n = 0
        var stack = [node]
        while let c = stack.popLast() { n += 1; stack.append(contentsOf: nodes[c].children) }
        return n
    }

    /// Removes every move the user explored (with the moves after it), wherever it sits, including explored
    /// moves that continue past the imported game's last move. Imported moves and variations stay, and
    /// ids are rebuilt. Returns how many moves went and where each survivor's id moved (old → new).
    @discardableResult
    public mutating func clearExplored() -> (removed: Int, remap: [Int: Int]) {
        let before = nodes.count
        for i in nodes.indices where nodes[i].explored {
            if let p = nodes[i].parent { nodes[p].children.removeAll { $0 == i } }
        }
        let remap = compact()
        return (before - nodes.count, remap)
    }

    /// The explored flags in a persisted form: one "0"/"1" per move, depth-first in children order (the order
    /// PGN export writes and parsing rebuilds), root excluded.
    public var exploredSignature: String {
        var out = ""
        var stack = [0]
        while let c = stack.popLast() {
            if c != 0 { out.append(nodes[c].explored ? "1" : "0") }
            stack.append(contentsOf: nodes[c].children.reversed())
        }
        return out
    }

    /// Restores flags saved by `exploredSignature`; ignored when it doesn't match this tree's size.
    public mutating func applyExploredSignature(_ sig: String) {
        guard sig.count == nodes.count - 1 else { return }
        var bits = Array(sig)[...]
        var stack = [0]
        while let c = stack.popLast() {
            if c != 0 { nodes[c].explored = bits.removeFirst() == "1" }
            stack.append(contentsOf: nodes[c].children.reversed())
        }
    }

    @discardableResult
    mutating func compact() -> [Int: Int] {
        var keep = [Int](); var stack = [0]
        while let n = stack.popLast() { keep.append(n); stack.append(contentsOf: nodes[n].children) }
        keep.sort()
        var remap: [Int: Int] = [:]
        for (i, k) in keep.enumerated() { remap[k] = i }
        nodes = keep.map { k in
            var n = nodes[k]
            n.id = remap[k]!
            n.parent = n.parent.flatMap { remap[$0] }
            n.children = n.children.compactMap { remap[$0] }
            return n
        }
        return remap
    }

    // MARK: Convenience

    public func finalOutcome(of node: Int) -> String? {
        let p = nodes[node].position
        if p.isCheckmate { return p.turn == .white ? "0-1" : "1-0" }
        if p.isStalemate || p.isInsufficientMaterial { return "1/2-1/2" }
        return nil
    }

    public var mainlineSAN: [String] { mainline().dropFirst().map { nodes[$0].san } }
}
