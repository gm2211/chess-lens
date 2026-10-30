import Foundation

/// Finds the two squares tinted by a last-move highlight: squares whose background colour deviates strongly from
/// the typical light/dark colour of the board, when exactly two clearly stand out.
enum LastMoveDetector {
    struct Cell: Equatable { var row: Int; var file: Int }

    /// Returns `[]` or two cells (image orientation, row 0 = top).
    static func detect(_ img: RasterImage, grid: BoardGrid) -> [Cell] {
        // Corner patch colours of every square (corners are the least likely to be covered by pieces).
        var patches = [[[Double]]](repeating: [], count: 64)
        let p = max(2.0, 0.16 * grid.s), inset = 0.05 * grid.s
        for row in 0..<8 {
            for file in 0..<8 {
                let cx = grid.x0 + Double(file) * grid.s, cy = grid.y0 + Double(row) * grid.s
                let corners = [(cx + inset, cy + inset), (cx + grid.s - inset - p, cy + inset), (cx + inset, cy + grid.s - inset - p), (cx + grid.s - inset - p, cy + grid.s - inset - p)]
                for (px, py) in corners { if let m = meanRGB(img, px, py, p) { patches[row * 8 + file].append(m) } }
                guard !patches[row * 8 + file].isEmpty else { return [] }
            }
        }
        // Reference colour per square parity (median over all corner patches of that parity).
        var reference: [[Double]] = [[], []]
        for parity in 0..<2 {
            let all = (0..<64).filter { (($0 / 8) + ($0 % 8)) % 2 == parity }.flatMap { patches[$0] }
            reference[parity] = (0..<3).map { c in
                let v = all.map { $0[c] }.sorted()
                return v[v.count / 2]
            }
        }
        // A highlight tints every corner of a square; a caption, arrow or label only some. Use the smallest deviation.
        let dev: [Double] = (0..<64).map { i in
            let r = reference[((i / 8) + (i % 8)) % 2]
            return patches[i].map { pt in
                // Opponent-colour distance (chroma) plus a smaller luminance term: highlights shift chroma,
                // while dark captions and image borders mostly shift luminance.
                let du = (pt[0] - pt[1]) - (r[0] - r[1])
                let dv = ((pt[0] + pt[1]) / 2 - pt[2]) - ((r[0] + r[1]) / 2 - r[2])
                let dl = (0.299 * pt[0] + 0.587 * pt[1] + 0.114 * pt[2]) - (0.299 * r[0] + 0.587 * r[1] + 0.114 * r[2])
                return (du * du + dv * dv).squareRoot() + 0.3 * abs(dl)
            }.min() ?? 0
        }
        let order = (0..<64).sorted { dev[$0] > dev[$1] }
        let d0 = dev[order[0]], d1 = dev[order[1]], d2 = dev[order[2]]
        _ = d0
        // Two clearly tinted squares, with a clear gap to everything else.
        guard d1 >= 14, d2 < 0.55 * d1 else { return [] }
        return [order[0], order[1]].map { Cell(row: $0 / 8, file: $0 % 8) }
    }

    private static func meanRGB(_ img: RasterImage, _ x0: Double, _ y0: Double, _ side: Double) -> [Double]? {
        let xa = max(0, Int(x0.rounded())), ya = max(0, Int(y0.rounded()))
        let xb = min(img.width, max(xa + 1, Int((x0 + side).rounded()))), yb = min(img.height, max(ya + 1, Int((y0 + side).rounded())))
        guard xa < img.width, ya < img.height, xb > xa, yb > ya else { return nil }
        var sum = [0.0, 0.0, 0.0]
        for y in ya..<yb {
            for x in xa..<xb {
                let o = (y * img.width + x) * 4
                sum[0] += Double(img.rgba[o]); sum[1] += Double(img.rgba[o + 1]); sum[2] += Double(img.rgba[o + 2])
            }
        }
        let n = Double((xb - xa) * (yb - ya))
        return sum.map { $0 / n }
    }
}
