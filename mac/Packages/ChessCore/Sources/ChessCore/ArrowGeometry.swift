import Foundation

/// A point in board drawing space (any unit; the caller picks the scale).
public struct ArrowPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A move arrow before overlap resolution. Candidates are passed best-first.
/// `rank` is the engine line's 1-based rank (0 when the arrow is not an engine line); it only labels the ring
/// left behind when the arrow is dropped.
public struct ArrowCandidate: Equatable, Sendable {
    public var from: Square
    public var to: Square
    public var rank: Int
    public init(from: Square, to: Square, rank: Int = 0) { self.from = from; self.to = to; self.rank = rank }
}

/// The ring left where a dropped alternative would have pointed, carrying that line's rank.
public struct ArrowDot: Equatable, Sendable {
    public var square: Square
    public var rank: Int
    public init(square: Square, rank: Int) { self.square = square; self.rank = rank }
}

/// The closed outline of one arrow (shaft and head as a single polygon) plus a round cap at its start.
public struct ArrowShape: Equatable, Sendable {
    public var polygon: [ArrowPoint]
    public var capCenter: ArrowPoint
    public var capRadius: Double
}

/// Pure arrow math, independent of any drawing framework (lichess / chess.com conventions).
public enum ArrowGeometry {
    /// Shaft thickness in squares: the best move is bold, alternatives are slimmer.
    public static func shaftWidth(primary: Bool) -> Double { primary ? 0.18 : 0.11 }
    public static func headLength(primary: Bool) -> Double { primary ? 0.45 : 0.38 }
    /// Head width as a multiple of the shaft thickness.
    public static let headWidthFactor = 2.6
    /// How far the shaft starts from the origin square's centre, in squares.
    public static let startInset = 0.25
    /// How far the tip stops short of the target square's centre, in squares.
    public static let tipGap = 0.08
    /// Alternatives more than this many win-percent points worse than the best are not drawn.
    public static let maxAlternativeGap = 20.0

    /// Opacity of an alternative line given how much win chance it gives up versus the best (percent points):
    /// 0.55 within 3 points, fading linearly to 0.25 at 15 points and beyond.
    public static func alternativeOpacity(gap: Double) -> Double {
        let t = min(1, max(0, (gap - 3) / 12))
        return 0.55 - 0.30 * t
    }

    public static func isKnightMove(from: Square, to: Square) -> Bool {
        let df = abs(Sq.file(from) - Sq.file(to)), dr = abs(Sq.rank(from) - Sq.rank(to))
        return (df == 1 && dr == 2) || (df == 2 && dr == 1)
    }

    /// Drops arrows that would sit on top of a better one and reports the targets to mark with a ring instead,
    /// each carrying the dropped candidate's rank.
    /// `candidates` must be best-first. An arrow is dropped when it shares its target with a kept arrow,
    /// or shares its origin and runs the same way along the same line (its head would land on the longer shaft);
    /// in the second case its target gets a ring unless a kept arrow already ends there.
    public static func resolveOverlaps(_ candidates: [ArrowCandidate]) -> (arrows: [ArrowCandidate], dots: [ArrowDot]) {
        var kept: [ArrowCandidate] = []
        var dots: [ArrowDot] = []
        for c in candidates {
            if kept.contains(where: { $0.to == c.to }) { continue }
            if kept.contains(where: { $0.from == c.from && collinearSameWay($0, c) }) {
                if !dots.contains(where: { $0.square == c.to }) { dots.append(ArrowDot(square: c.to, rank: c.rank)) }
                continue
            }
            kept.append(c)
        }
        dots.removeAll { d in kept.contains { $0.to == d.square } }
        return (kept, dots)
    }

    static func collinearSameWay(_ a: ArrowCandidate, _ b: ArrowCandidate) -> Bool {
        let ax = Sq.file(a.to) - Sq.file(a.from), ay = Sq.rank(a.to) - Sq.rank(a.from)
        let bx = Sq.file(b.to) - Sq.file(b.from), by = Sq.rank(b.to) - Sq.rank(b.from)
        return ax * by - ay * bx == 0 && ax * bx + ay * by > 0
    }

    /// Outline for an arrow between two square centres. `cell` is the square size in drawing units.
    /// A knight move is an L: the long leg first, then the short one.
    public static func shape(from p0: ArrowPoint, to p1: ArrowPoint, cell: Double, primary: Bool, knight: Bool) -> ArrowShape? {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        guard hypot(dx, dy) > cell * 0.2 else { return nil }
        // Waypoints: origin, optional corner, target.
        var pts = [p0]
        if knight {
            pts.append(abs(dx) > abs(dy) ? ArrowPoint(x: p1.x, y: p0.y) : ArrowPoint(x: p0.x, y: p1.y))
        }
        pts.append(p1)
        func unit(_ a: ArrowPoint, _ b: ArrowPoint) -> ArrowPoint {
            let l = hypot(b.x - a.x, b.y - a.y); return ArrowPoint(x: (b.x - a.x) / l, y: (b.y - a.y) / l)
        }
        let u0 = unit(pts[0], pts[1])
        let uLast = unit(pts[pts.count - 2], pts[pts.count - 1])
        // Trim the start and the tip.
        let start = ArrowPoint(x: p0.x + u0.x * cell * startInset, y: p0.y + u0.y * cell * startInset)
        let tip = ArrowPoint(x: p1.x - uLast.x * cell * tipGap, y: p1.y - uLast.y * cell * tipGap)
        let lastLegStart = pts.count == 3 ? pts[1] : start
        let lastLegLen = hypot(tip.x - lastLegStart.x, tip.y - lastLegStart.y)
        let half = cell * shaftWidth(primary: primary) / 2
        let headW = half * 2 * headWidthFactor
        let headL = min(cell * headLength(primary: primary), lastLegLen * 0.85)
        let base = ArrowPoint(x: tip.x - uLast.x * headL, y: tip.y - uLast.y * headL)

        // Shaft centre line: start [corner] base.
        var line = [start]
        if pts.count == 3 { line.append(pts[1]) }
        line.append(base)
        // Offset the centre line by `half` to each side (mitred at the corner).
        func normals(_ line: [ArrowPoint]) -> [ArrowPoint] {
            (0..<(line.count - 1)).map { let u = unit(line[$0], line[$0 + 1]); return ArrowPoint(x: -u.y, y: u.x) }
        }
        let ns = normals(line)
        func side(_ sign: Double) -> [ArrowPoint] {
            var out: [ArrowPoint] = []
            for i in 0..<line.count {
                let n: ArrowPoint
                var k = half
                if i == 0 { n = ns[0] }
                else if i == line.count - 1 { n = ns[ns.count - 1] }
                else {
                    let a = ns[i - 1], b = ns[i]
                    let d = 1 + a.x * b.x + a.y * b.y
                    n = ArrowPoint(x: (a.x + b.x) / d, y: (a.y + b.y) / d); k = half
                }
                out.append(ArrowPoint(x: line[i].x + sign * n.x * k, y: line[i].y + sign * n.y * k))
            }
            return out
        }
        let nl = ArrowPoint(x: -uLast.y, y: uLast.x)
        let wing = headW / 2
        var poly = side(1)
        poly.append(ArrowPoint(x: base.x + nl.x * wing, y: base.y + nl.y * wing))
        poly.append(tip)
        poly.append(ArrowPoint(x: base.x - nl.x * wing, y: base.y - nl.y * wing))
        poly.append(contentsOf: side(-1).reversed())
        return ArrowShape(polygon: poly, capCenter: start, capRadius: half)
    }
}
