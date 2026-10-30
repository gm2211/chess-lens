import CoreGraphics
import Dispatch
import Foundation

struct Dataset {
    var pixels: [UInt8]  // N * sampleSize * sampleSize * 3, RGB, row-major
    var labels: [Int32]
    var count: Int { labels.count }
    static let imageBytes = sampleSize * sampleSize * 3
}

func rgbBytes(of image: CGImage) -> [UInt8] {
    let ctx = CGContext(data: nil, width: sampleSize, height: sampleSize, bitsPerComponent: 8, bytesPerRow: sampleSize * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 0, count: Dataset.imageBytes)
    for i in 0..<(sampleSize * sampleSize) {
        out[i * 3] = p[i * 4]
        out[i * 3 + 1] = p[i * 4 + 1]
        out[i * 3 + 2] = p[i * 4 + 2]
    }
    return out
}

/// Renders `perClass` samples per class in parallel. `heldOut` renders with the held-out piece set and
/// alternates between the held-out theme and random seen themes.
func generateDataset(perClass: Int, seed: UInt64, renderer: SampleRenderer, heldOut: PieceSet? = nil) -> Dataset {
    let total = perClass * classLabels.count
    var pixels = [UInt8](repeating: 0, count: total * Dataset.imageBytes)
    var labels = [Int32](repeating: 0, count: total)
    pixels.withUnsafeMutableBufferPointer { pbuf in
        labels.withUnsafeMutableBufferPointer { lbuf in
            let pp = pbuf.baseAddress!, lp = lbuf.baseAddress!
            nonisolated(unsafe) let pp2 = pp
            nonisolated(unsafe) let lp2 = lp
            DispatchQueue.concurrentPerform(iterations: total) { i in
                autoreleasepool {
                if i % 20 == 0 { memoryGuard("generate") }
                let label = i % classLabels.count
                var rng = SplitMix64(seed: seed &* 1_000_003 &+ UInt64(i))
                let img: CGImage
                if let held = heldOut {
                    img = renderer.render(label: label, rng: &rng, pieceSet: held, theme: (i / classLabels.count) % 2 == 0 ? heldOutTheme : randomTheme(&rng))
                } else {
                    img = renderer.render(label: label, rng: &rng)
                }
                let bytes = rgbBytes(of: img)
                bytes.withUnsafeBufferPointer { b in
                    (pp2 + i * Dataset.imageBytes).update(from: b.baseAddress!, count: Dataset.imageBytes)
                }
                lp2[i] = Int32(label)
                }
            }
        }
    }
    return Dataset(pixels: pixels, labels: labels)
}
