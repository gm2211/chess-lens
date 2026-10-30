import Foundation

/// Position of the 8x8 grid in working-resolution pixel coordinates (continuous; pixel k covers [k, k+1)).
struct BoardGrid: Sendable, Equatable {
    var x0: Double
    var y0: Double
    var s: Double  // square side
}

/// Finds the checkerboard in a screenshot.
///
/// 1. Edge strength: |gradient| projected along columns/rows. The 7 inner grid lines of a checkerboard
///    are strong at every square boundary, so for each axis we search for the (offset, spacing) pair whose 7 equally
///    spaced lines have the most edge energy relative to the points half-way between them.
/// 2. The best offsets on each axis are paired (same square size) and scored in 2D, restricting each line's energy
///    to the extent of the board, which discards structures that only match on one axis.
/// 3. Candidates are verified with a checkerboard alternation test on the corner colours of every square
///    (corners are rarely covered by pieces), which also resolves one-square-shift ambiguities.
/// 4. The winner is refined with a sub-pixel local search.
struct BoardLocator {
    private struct Axis {
        let n: Int  // boundaries are 0...n
        let other: Int
        let cum: [Float]  // cum[b * (other + 1) + k] = sum of edge strength over the first k samples of boundary b
        let prof: [Double]  // 3-boundary window of total edge strength

        @inline(__always) func win(_ k: Int, _ a: Int, _ b: Int) -> Double {
            var s: Float = 0
            for j in (k - 1)...(k + 1) {
                let jj = min(max(j, 0), n)
                s += cum[jj * (other + 1) + b] - cum[jj * (other + 1) + a]
            }
            return Double(s)
        }

        func line(_ pos: Double, _ a: Int, _ b: Int) -> Double {
            let f = Int(pos.rounded(.down))
            let t = pos - Double(f)
            return win(f, a, b) * (1 - t) + win(f + 1, a, b) * t
        }

        func profLine(_ pos: Double) -> Double {
            let f = Int(pos.rounded(.down))
            let t = pos - Double(f)
            let a = prof[min(max(f, 0), n)], b = prof[min(max(f + 1, 0), n)]
            return a * (1 - t) + b * t
        }
    }

    private let img: RasterImage
    private let w: Int
    private let h: Int
    private let xAxis: Axis  // vertical lines (x boundaries), ranges over y
    private let yAxis: Axis  // horizontal lines (y boundaries), ranges over x
    private let integral: [Double]

    init(_ img: RasterImage) {
        self.img = img
        w = img.width
        h = img.height
        let g = img.gray
        let w = self.w, h = self.h
        let clampMax: Float = 64

        // Vertical edges: boundary b lies between pixel columns b-1 and b.
        var cv = [Float](repeating: 0, count: (w + 1) * (h + 1))
        if w >= 5 {
            for b in 2...(w - 2) {
                var run: Float = 0
                let base = b * (h + 1)
                for y in 0..<h {
                    let o = y * w
                    let d = abs((g[o + b] + g[o + b + 1]) - (g[o + b - 1] + g[o + b - 2])) * 0.5
                    run += min(d, clampMax)
                    cv[base + y + 1] = run
                }
            }
        }
        var ch = [Float](repeating: 0, count: (h + 1) * (w + 1))
        if h >= 5 {
            for b in 2...(h - 2) {
                var run: Float = 0
                let base = b * (w + 1)
                for x in 0..<w {
                    let d = abs((g[b * w + x] + g[(b + 1) * w + x]) - (g[(b - 1) * w + x] + g[(b - 2) * w + x])) * 0.5
                    run += min(d, clampMax)
                    ch[base + x + 1] = run
                }
            }
        }
        func profile(_ cum: [Float], n: Int, other: Int) -> [Double] {
            let total = (0...n).map { Double(cum[$0 * (other + 1) + other]) }
            return (0...n).map { b in
                (max(0, b - 1)...min(n, b + 1)).reduce(0.0) { $0 + total[$1] }
            }
        }
        xAxis = Axis(n: w, other: h, cum: cv, prof: profile(cv, n: w, other: h))
        yAxis = Axis(n: h, other: w, cum: ch, prof: profile(ch, n: h, other: w))

        var ii = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(g[y * w + x])
                ii[(y + 1) * (w + 1) + x + 1] = ii[y * (w + 1) + x + 1] + row
            }
        }
        integral = ii
    }

    // MARK: 1D search

    private struct Cand {
        var x0: Double
        var s: Double
        var f: Double
    }

    private func score1D(_ axis: Axis, _ x0: Double, _ s: Double) -> Double {
        var l = 0.0, m = 0.0
        for i in 1...7 { l += axis.profLine(x0 + Double(i) * s) }
        for i in 0...7 { m += axis.profLine(x0 + (Double(i) + 0.5) * s) }
        return l / 7 - m / 8
    }

    private func candidates1D(_ axis: Axis, sMin: Double, sMax: Double, keep: Int) -> [Cand] {
        let tol = 4.0
        var all: [Cand] = []
        var s = sMin
        while s <= sMax {
            let lo = -tol
            let hi = Double(axis.n) - 8 * s + tol
            if hi >= lo {
                var vals: [Double] = []
                var x = lo
                while x <= hi {
                    vals.append(score1D(axis, x, s))
                    x += 1
                }
                for i in 0..<vals.count where vals[i] > 0 {
                    let left = i > 0 ? vals[i - 1] : -Double.infinity
                    let right = i + 1 < vals.count ? vals[i + 1] : -Double.infinity
                    if vals[i] >= left && vals[i] >= right { all.append(Cand(x0: lo + Double(i), s: s, f: vals[i])) }
                }
            }
            s += 0.5
        }
        all.sort { $0.f > $1.f }
        var out: [Cand] = []
        for c in all {
            if out.count >= keep { break }
            if out.contains(where: { abs($0.x0 - c.x0) <= 4 && abs($0.s - c.s) <= 1.0 }) { continue }
            out.append(c)
        }
        return out
    }

    // MARK: 2D scoring

    private func inBounds(_ g: BoardGrid) -> Bool {
        let tol = 4.0
        return g.s > 4 && g.x0 >= -tol && g.y0 >= -tol && g.x0 + 8 * g.s <= Double(w) + tol && g.y0 + 8 * g.s <= Double(h) + tol
    }

    private func edge2D(_ g: BoardGrid) -> Double {
        guard inBounds(g) else { return 0 }
        func axisScore(_ axis: Axis, _ p0: Double, _ q0: Double, _ n: Int) -> Double {
            let a = max(0, Int(q0.rounded())), b = min(n, Int((q0 + 8 * g.s).rounded()))
            guard b - a > Int(4 * g.s) else { return 0 }
            var l = 0.0, m = 0.0
            for i in 1...7 { l += axis.line(p0 + Double(i) * g.s, a, b) }
            for i in 0...7 { m += axis.line(p0 + (Double(i) + 0.5) * g.s, a, b) }
            return (l / 7 - m / 8) / Double(b - a)
        }
        let ev = axisScore(xAxis, g.x0, g.y0, h)
        let eh = axisScore(yAxis, g.y0, g.x0, w)
        if ev <= 0 || eh <= 0 { return 0 }
        return (ev * eh).squareRoot()
    }

    private func patchMean(_ x0: Double, _ y0: Double, _ side: Double) -> Double? {
        let xa = max(0, Int(x0.rounded())), ya = max(0, Int(y0.rounded()))
        let xb = min(w, max(xa + 1, Int((x0 + side).rounded()))), yb = min(h, max(ya + 1, Int((y0 + side).rounded())))
        guard xa < w, ya < h, xb > xa, yb > ya else { return nil }
        let W = w + 1
        let sum = integral[yb * W + xb] - integral[ya * W + xb] - integral[yb * W + xa] + integral[ya * W + xa]
        return sum / Double((xb - xa) * (yb - ya))
    }

    /// Background luma of every square, estimated from the median of its four corner patches.
    func backgroundLuma(_ g: BoardGrid) -> [[Double?]] {
        let p = max(2, 0.16 * g.s), inset = 0.05 * g.s
        var out = [[Double?]](repeating: [Double?](repeating: nil, count: 8), count: 8)
        for j in 0..<8 {
            for i in 0..<8 {
                let cx = g.x0 + Double(i) * g.s, cy = g.y0 + Double(j) * g.s
                let pts = [(cx + inset, cy + inset), (cx + g.s - inset - p, cy + inset), (cx + inset, cy + g.s - inset - p), (cx + g.s - inset - p, cy + g.s - inset - p)]
                let vals = pts.compactMap { patchMean($0.0, $0.1, p) }.sorted()
                if vals.count >= 3 { out[j][i] = (vals[vals.count / 2 - 1] + vals[vals.count / 2]) / 2 }
                else if !vals.isEmpty { out[j][i] = vals[vals.count / 2] }
            }
        }
        return out
    }

    /// 0...1: how consistently neighbouring squares alternate light/dark with one global polarity.
    func alternation(_ g: BoardGrid) -> Double {
        let bg = backgroundLuma(g)
        var sum = 0.0
        var pairs = 0.0
        let threshold = 3.0
        for j in 0..<8 {
            for i in 0..<8 {
                guard let a = bg[j][i] else { pairs += (i < 7 ? 1 : 0) + (j < 7 ? 1 : 0); continue }
                let parity: Double = (i + j) % 2 == 0 ? 1 : -1
                if i < 7 {
                    pairs += 1
                    if let b = bg[j][i + 1] { let d = (a - b) * parity; if abs(d) > threshold { sum += d > 0 ? 1 : -1 } }
                }
                if j < 7 {
                    pairs += 1
                    if let b = bg[j + 1][i] { let d = (a - b) * parity; if abs(d) > threshold { sum += d > 0 ? 1 : -1 } }
                }
            }
        }
        return abs(sum) / max(1, pairs)
    }

    private func refine(_ start: BoardGrid) -> BoardGrid {
        var best = start
        var bestE = edge2D(start)
        for (ps, ss) in [(2.0, 1.0), (1.0, 0.5), (0.5, 0.25), (0.25, 0.1), (0.1, 0.05)] {
            var improved = true
            var iter = 0
            while improved && iter < 25 {
                improved = false
                iter += 1
                let moves: [BoardGrid] = [
                    BoardGrid(x0: best.x0 + ps, y0: best.y0, s: best.s), BoardGrid(x0: best.x0 - ps, y0: best.y0, s: best.s),
                    BoardGrid(x0: best.x0, y0: best.y0 + ps, s: best.s), BoardGrid(x0: best.x0, y0: best.y0 - ps, s: best.s),
                    BoardGrid(x0: best.x0 - 4 * ss, y0: best.y0 - 4 * ss, s: best.s + ss), BoardGrid(x0: best.x0 + 4 * ss, y0: best.y0 + 4 * ss, s: best.s - ss),
                    BoardGrid(x0: best.x0, y0: best.y0, s: best.s + ss), BoardGrid(x0: best.x0, y0: best.y0, s: best.s - ss),
                    BoardGrid(x0: best.x0 - 8 * ss, y0: best.y0 - 8 * ss, s: best.s + ss), BoardGrid(x0: best.x0 + 8 * ss, y0: best.y0 + 8 * ss, s: best.s - ss),
                ]
                for m in moves {
                    let e = edge2D(m)
                    if e > bestE + 1e-9 { best = m; bestE = e; improved = true }
                }
            }
        }
        return best
    }

    /// Returns the board grid in working-resolution coordinates, or nil when no checkerboard is found.
    func locate() -> BoardGrid? {
        let sMin = 7.0
        let sMax = Double(min(w, h)) / 8 * 1.03
        guard sMax > sMin else { return nil }
        let xs = candidates1D(xAxis, sMin: sMin, sMax: sMax, keep: 60)
        let ys = candidates1D(yAxis, sMin: sMin, sMax: sMax, keep: 60)
        if xs.isEmpty || ys.isEmpty { return nil }

        struct Scored { var grid: BoardGrid; var e: Double; var rank: Double }
        var scored: [Scored] = []
        for xc in xs {
            for yc in ys where abs(xc.s - yc.s) <= 0.05 * max(xc.s, yc.s) + 1.0 {
                let g = BoardGrid(x0: xc.x0, y0: yc.x0, s: (xc.s + yc.s) / 2)
                let e = edge2D(g)
                if e <= 0 { continue }
                scored.append(Scored(grid: g, e: e, rank: e))
            }
        }
        scored.sort { $0.rank > $1.rank }
        // Verify the strongest candidates with the alternation test and refine the best few.
        var finalists: [Scored] = []
        var seen: [BoardGrid] = []
        for c in scored {
            if seen.count >= 40 || finalists.count >= 8 { break }
            if seen.contains(where: { abs($0.x0 - c.grid.x0) < 6 && abs($0.y0 - c.grid.y0) < 6 && abs($0.s - c.grid.s) < 3 }) { continue }
            seen.append(c.grid)
            let a = alternation(c.grid)
            if a < 0.45 { continue }
            finalists.append(Scored(grid: c.grid, e: c.e, rank: c.e * a * a * a))
        }
        var best: Scored?
        for f in finalists {
            let g = refine(f.grid)
            let e = edge2D(g)
            let a = alternation(g)
            guard a >= 0.45 else { continue }
            let r = e * a * a * a
            if best == nil || r > best!.rank { best = Scored(grid: g, e: e, rank: r) }
        }
        return best?.grid
    }
}
