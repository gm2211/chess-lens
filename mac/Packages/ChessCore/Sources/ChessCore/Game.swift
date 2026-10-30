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

    public init(id: Int, parent: Int?, move: Move?, san: String, position: Position, comment: String? = nil, nags: [Int] = [], children: [Int] = []) {
        self.id = id; self.parent = parent; self.move = move; self.san = san
        self.position = position; self.comment = comment; self.nags = nags; self.children = children
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

    /// Adds `move` after `node`, reusing an existing identical child. Returns the child id.
    @discardableResult
    public mutating func addMove(_ move: Move, after node: Int) throws -> Int {
        if let existing = nodes[node].children.first(where: { nodes[$0].move == move }) { return existing }
        let pos = nodes[node].position
        let san = pos.san(move)
        let next = try pos.applying(move)
        let id = nodes.count
        nodes.append(GameNode(id: id, parent: node, move: move, san: san, position: next))
        nodes[node].children.append(id)
        return id
    }

    /// Node ids from the root to `node` inclusive.
    public func path(to node: Int) -> [Int] {
        var out: [Int] = []
        var cur: Int? = node
        while let c = cur { out.append(c); cur = nodes[c].parent }
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

    mutating func compact() {
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
