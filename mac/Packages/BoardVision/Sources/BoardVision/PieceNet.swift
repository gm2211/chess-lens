import Accelerate
import CoreGraphics
import Foundation

/// Small CNN that classifies one square crop into 13 classes (empty + 12 pieces).
///
/// Architecture (must match `NetSpec` in `mac/Tools/TrainBoardModel`):
///   input 64x64x3 (NHWC, v/255 - 0.5), 4 x [conv3x3 same + ReLU + maxpool2] with 48/96/128/192 channels,
///   flatten (h, w, c) -> dense 256 + ReLU -> dense 13.
/// Inference runs on the CPU through Accelerate (im2col + sgemm); weights are stored as Float16 in `PieceNet.bin`.
final class PieceNet: Sendable {
    static let inputSize = 64
    static let channels = [3, 48, 96, 128, 192]
    static let flat = 4 * 4 * 192
    static let hidden = 256
    static let classCount = 13

    private let tensors: [[Float]]

    /// Class order shared with the training tool.
    static let classLabels = ["empty", "wP", "wN", "wB", "wR", "wQ", "wK", "bP", "bN", "bB", "bR", "bQ", "bK"]

    init?(weights data: Data) {
        guard data.count >= 12, String(data: data.prefix(4), encoding: .utf8) == "PNET" else { return nil }
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        guard u32(4) == 1 else { return nil }
        let count = u32(8)
        guard count == 12, data.count >= 12 + 4 * count else { return nil }
        var sizes: [Int] = []
        for i in 0..<count { sizes.append(u32(12 + 4 * i)) }
        var expected: [Int] = []
        for l in 0..<4 {
            expected.append(9 * Self.channels[l] * Self.channels[l + 1])
            expected.append(Self.channels[l + 1])
        }
        expected += [Self.flat * Self.hidden, Self.hidden, Self.hidden * Self.classCount, Self.classCount]
        guard sizes == expected, data.count == 12 + 4 * count + 2 * sizes.reduce(0, +) else { return nil }
        var offset = 12 + 4 * count
        var out: [[Float]] = []
        for n in sizes {
            var t = [Float](repeating: 0, count: n)
            data.withUnsafeBytes { raw in
                for i in 0..<n {
                    let bits = UInt16(raw[offset + 2 * i]) | UInt16(raw[offset + 2 * i + 1]) << 8
                    t[i] = Float(Float16(bitPattern: bits))
                }
            }
            offset += 2 * n
            out.append(t)
        }
        tensors = out
    }

    /// Loads the bundled weights.
    static func loadBundled() -> PieceNet? {
        guard let url = Bundle.module.url(forResource: "PieceNet", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return PieceNet(weights: data)
    }

    /// `pixels`: 64*64*3 bytes RGB. Returns softmax probabilities over `classLabels`.
    func predict(_ pixels: [UInt8]) -> [Float] {
        let size = Self.inputSize
        var cur = [Float](repeating: 0, count: size * size * 3)
        for i in 0..<cur.count { cur[i] = Float(pixels[i]) / 255 - 0.5 }
        var side = size
        for l in 0..<4 {
            let cin = Self.channels[l], cout = Self.channels[l + 1]
            cur = convReLUPool(cur, side: side, cin: cin, cout: cout, weights: tensors[2 * l], bias: tensors[2 * l + 1])
            side /= 2
        }
        // Dense 1
        var hidden = [Float](repeating: 0, count: Self.hidden)
        cblas_sgemv(CblasRowMajor, CblasTrans, Int32(Self.flat), Int32(Self.hidden), 1, tensors[8], Int32(Self.hidden), cur, 1, 0, &hidden, 1)
        for i in 0..<Self.hidden { hidden[i] = max(0, hidden[i] + tensors[9][i]) }
        var logits = [Float](repeating: 0, count: Self.classCount)
        cblas_sgemv(CblasRowMajor, CblasTrans, Int32(Self.hidden), Int32(Self.classCount), 1, tensors[10], Int32(Self.classCount), hidden, 1, 0, &logits, 1)
        for i in 0..<Self.classCount { logits[i] += tensors[11][i] }
        let m = logits.max() ?? 0
        var exps = logits.map { Float(exp(Double($0 - m))) }
        let sum = exps.reduce(0, +)
        for i in 0..<exps.count { exps[i] /= sum }
        return exps
    }

    private func convReLUPool(_ input: [Float], side: Int, cin: Int, cout: Int, weights: [Float], bias: [Float]) -> [Float] {
        let k = 9 * cin
        let pixels = side * side
        var col = [Float](repeating: 0, count: pixels * k)
        input.withUnsafeBufferPointer { src in
            col.withUnsafeMutableBufferPointer { dst in
                for y in 0..<side {
                    for x in 0..<side {
                        var o = (y * side + x) * k
                        for dy in -1...1 {
                            let yy = y + dy
                            for dx in -1...1 {
                                let xx = x + dx
                                if yy >= 0 && yy < side && xx >= 0 && xx < side {
                                    let s = (yy * side + xx) * cin
                                    for c in 0..<cin { dst[o + c] = src[s + c] }
                                }
                                o += cin
                            }
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: pixels * cout)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(pixels), Int32(cout), Int32(k), 1, col, Int32(k), weights, Int32(cout), 0, &out, Int32(cout))
        let half = side / 2
        var pooled = [Float](repeating: 0, count: half * half * cout)
        out.withUnsafeBufferPointer { o in
            bias.withUnsafeBufferPointer { b in
                pooled.withUnsafeMutableBufferPointer { p in
                    for y in 0..<half {
                        for x in 0..<half {
                            for c in 0..<cout {
                                let i00 = ((2 * y) * side + 2 * x) * cout + c
                                let m = max(max(o[i00], o[i00 + cout]), max(o[i00 + side * cout], o[i00 + side * cout + cout]))
                                p[(y * half + x) * cout + c] = max(0, m + b[c])  // max-pool then bias+ReLU == ReLU(bias + conv) pooled
                            }
                        }
                    }
                }
            }
        }
        return pooled
    }
}
