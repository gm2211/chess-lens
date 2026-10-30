import CoreGraphics
import Dispatch
import Foundation

/// Geometry of the located board in ORIGINAL image pixel coordinates (origin top-left).
struct BoardGeometry: Sendable {
    var x0: Double
    var y0: Double
    var side: Double  // square side

    func cell(file: Int, row: Int) -> CGRect {
        CGRect(x: x0 + Double(file) * side, y: y0 + Double(row) * side, width: side, height: side)
    }

    var rect: CGRect { CGRect(x: x0, y: y0, width: side * 8, height: side * 8) }
}

enum SquareClassifier {
    /// Context around the square, as a fraction of its side on each side. Must match the training tool.
    static let margin = 0.06

    /// Crops `cell` (plus margin) out of `image` and resamples to 64x64 RGB.
    static func crop(_ image: CGImage, cell: CGRect) -> [UInt8] {
        let size = PieceNet.inputSize
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
            return [UInt8](repeating: 128, count: size * size * 3)
        }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.interpolationQuality = .high
        let rect = cell.insetBy(dx: -margin * cell.width, dy: -margin * cell.height)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pre = rect.insetBy(dx: -2, dy: -2).integral.intersection(bounds)
        if !pre.isEmpty, let sub = image.cropping(to: pre) {
            let k = Double(size) / rect.width
            let dw = pre.width * k, dh = pre.height * k
            let dx = (pre.minX - rect.minX) * k
            let dy = Double(size) - (pre.minY - rect.minY) * k - dh
            ctx.draw(sub, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        }
        var out = [UInt8](repeating: 0, count: size * size * 3)
        for i in 0..<(size * size) {
            out[i * 3] = data[i * 4]
            out[i * 3 + 1] = data[i * 4 + 1]
            out[i * 3 + 2] = data[i * 4 + 2]
        }
        return out
    }

    /// Test-time augmentation: window scales applied around each square's centre; probabilities are averaged.
    static let windowScales: [Double] = [1.0, 0.92, 1.08]

    /// A bitmap-backed copy of `image`. Images straight from ImageIO (webp, jpeg, ...) decode lazily and
    /// can re-decode the whole picture for every `cropping`; decoding once makes the 192 crops cheap.
    static func decoded(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Class probabilities for all 64 cells, indexed `[row * 8 + file]` in image orientation (row 0 = top).
    static func classify(_ source: CGImage, geometry: BoardGeometry, net: PieceNet) -> [[Float]] {
        let image = decoded(source)
        var crops: [[UInt8]] = []
        crops.reserveCapacity(64 * windowScales.count)
        for row in 0..<8 {
            for file in 0..<8 {
                let cell = geometry.cell(file: file, row: row)
                for f in windowScales {
                    let d = (f - 1) / 2 * cell.width
                    crops.append(crop(image, cell: cell.insetBy(dx: -d, dy: -d)))
                }
            }
        }
        let results = ResultBox(count: crops.count)
        crops.withUnsafeBufferPointer { cropsPtr in
            nonisolated(unsafe) let cp = cropsPtr
            DispatchQueue.concurrentPerform(iterations: cp.count) { i in
                results.set(i, net.predict(cp[i]))
            }
        }
        let n = windowScales.count
        return (0..<64).map { cell in
            var avg = [Float](repeating: 0, count: PieceNet.classCount)
            for k in 0..<n { for c in 0..<PieceNet.classCount { avg[c] += results.values[cell * n + k][c] } }
            return avg.map { $0 / Float(n) }
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [[Float]]
    init(count: Int) { values = [[Float]](repeating: [], count: count) }
    func set(_ i: Int, _ v: [Float]) {
        lock.lock()
        values[i] = v
        lock.unlock()
    }
}
