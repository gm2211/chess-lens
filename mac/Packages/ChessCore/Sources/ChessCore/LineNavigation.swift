import Foundation

/// A branching point on a displayed line: `node` is the line's move there, `siblings` every alternative
/// at that ply (the parent's children, in order, `node` among them).
public struct LineFork: Sendable, Equatable {
    public var parent: Int
    public var node: Int
    public var siblings: [Int]

    public init(parent: Int, node: Int, siblings: [Int]) {
        self.parent = parent; self.node = node; self.siblings = siblings
    }
}

/// The "branch picker" model: the move list shows one line, root → `tip`, and the current node is always on it.
extension Game {
    /// The line ending at `tip` (root first). Falls back to the main line when `tip` is stale.
    public func displayLine(tip: Int) -> [Int] {
        let p = path(to: tip)
        return p.isEmpty ? mainline() : p
    }

    /// Whether `node` lies on the line root → `tip` (it is `tip` or one of its ancestors).
    public func isOnLine(_ node: Int, tip: Int) -> Bool {
        guard nodes.indices.contains(node) else { return false }
        var cur: Int? = tip
        while let c = cur, nodes.indices.contains(c) {
            if c == node { return true }
            cur = nodes[c].parent
        }
        return false
    }

    /// The tip to keep after moving to `id`: the current one when `id` is on its line, otherwise the end of
    /// the main continuation from `id`. Stale ids fall back to the main line's end.
    public func lineTip(afterGoto id: Int, currentTip: Int) -> Int {
        guard nodes.indices.contains(id) else { return mainline().last ?? 0 }
        if isOnLine(id, tip: currentTip) { return currentTip }
        return mainline(from: id).last ?? id
    }

    /// The node after `id` on the line root → `tip`, or nil when `id` is the tip or not on that line.
    public func nextOnLine(from id: Int, tip: Int) -> Int? {
        guard nodes.indices.contains(id), id != tip else { return nil }
        var cur: Int? = tip
        while let c = cur, nodes.indices.contains(c) {
            if nodes[c].parent == id { return c }
            cur = nodes[c].parent
        }
        return nil
    }

    /// Forks along `line`: every node whose parent has more than one child, with its ordered siblings.
    public func forks(on line: [Int]) -> [LineFork] {
        line.compactMap { id in
            guard nodes.indices.contains(id), let p = nodes[id].parent, nodes[p].children.count > 1 else { return nil }
            return LineFork(parent: p, node: id, siblings: nodes[p].children)
        }
    }

    /// Whether `node` is on the game's main line (first children all the way from the root).
    public func isOnMainline(_ node: Int) -> Bool {
        guard nodes.indices.contains(node) else { return false }
        var cur = node
        while let p = nodes[cur].parent {
            if nodes[p].children.first != cur { return false }
            cur = p
        }
        return true
    }

    /// The deepest node of `line` that is on the main line (the point where `line` leaves it).
    public func lastMainlineNode(on line: [Int]) -> Int {
        var last = 0
        for id in line {
            guard nodes.indices.contains(id), id == 0 || isMainlineChild(id) else { break }
            last = id
        }
        return last
    }

    private func isMainlineChild(_ id: Int) -> Bool {
        guard let p = nodes[id].parent else { return true }
        return nodes[p].children.first == id
    }

    /// The sibling `offset` steps from `node` among its parent's children (wrapping), or nil when it has none.
    public func sibling(of node: Int, offset: Int) -> Int? {
        guard nodes.indices.contains(node), let p = nodes[node].parent else { return nil }
        let kids = nodes[p].children
        guard kids.count > 1, let i = kids.firstIndex(of: node) else { return nil }
        let n = kids.count
        return kids[((i + offset) % n + n) % n]
    }

    /// The moves from the root to `node`, for finding the same line again after ids change.
    public func moves(to node: Int) -> [Move] {
        path(to: node).dropFirst().compactMap { nodes[$0].move }
    }

    /// The deepest node reached by playing `moves` from the root through existing children.
    public func locate(moves: [Move]) -> Int {
        var cur = 0
        for m in moves {
            guard let next = nodes[cur].children.first(where: { nodes[$0].move == m }) else { break }
            cur = next
        }
        return cur
    }
}
