import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Network layout. Keep in sync with `PieceNet` in the BoardVision package.
///   input 64x64x3 (NHWC, values v/255 - 0.5)
///   4 x [conv3x3 same + ReLU + maxpool2]  channels 48, 96, 128, 192  -> 4x4x192
///   flatten (h, w, c) -> dense 256 + ReLU -> dropout -> dense 13
enum NetSpec {
    static let convChannels = [3, 48, 96, 128, 192]
    static let flat = 4 * 4 * 192
    static let hidden = 256
    static let classes = 13
}

final class Trainer {
    let graph = MPSGraph()
    let device = MPSGraphDevice(mtlDevice: MTLCreateSystemDefaultDevice()!)
    let B = 128
    let queue = MTLCreateSystemDefaultDevice()!.makeCommandQueue()!
    var variables: [MPSGraphTensor] = []
    var shapes: [[Int]] = []
    var reads: [MPSGraphTensor] = []
    var x: MPSGraphTensor!
    var y: MPSGraphTensor!
    var lr: MPSGraphTensor!
    var loss: MPSGraphTensor!
    var evalLogits: MPSGraphTensor!
    var updateOps: [MPSGraphOperation] = []

    private func nsShape(_ s: [Int]) -> [NSNumber] { s.map { NSNumber(value: $0) } }

    private func makeVariable(_ shape: [Int], data: [Float], name: String) -> MPSGraphTensor {
        let d = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return graph.variable(with: d, shape: nsShape(shape), dataType: .float32, name: name)
    }

    private func heNormal(count: Int, fanIn: Int, rng: inout SplitMix64) -> [Float] {
        let std = sqrt(2.0 / Double(fanIn))
        return (0..<count).map { _ in
            let u1 = max(1e-9, Double(rng.uniform(0, 1))), u2 = Double(rng.uniform(0, 1))
            return Float(std * sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
    }

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var paramInfo: [(shape: [Int], data: [Float], name: String)] = []
        for l in 0..<4 {
            let cin = NetSpec.convChannels[l], cout = NetSpec.convChannels[l + 1]
            paramInfo.append(([3, 3, cin, cout], heNormal(count: 9 * cin * cout, fanIn: 9 * cin, rng: &rng), "conv\(l)w"))
            paramInfo.append(([1, 1, 1, cout], [Float](repeating: 0, count: cout), "conv\(l)b"))
        }
        paramInfo.append(([NetSpec.flat, NetSpec.hidden], heNormal(count: NetSpec.flat * NetSpec.hidden, fanIn: NetSpec.flat, rng: &rng), "fc1w"))
        paramInfo.append(([1, NetSpec.hidden], [Float](repeating: 0, count: NetSpec.hidden), "fc1b"))
        paramInfo.append(([NetSpec.hidden, NetSpec.classes], heNormal(count: NetSpec.hidden * NetSpec.classes, fanIn: NetSpec.hidden, rng: &rng), "fc2w"))
        paramInfo.append(([1, NetSpec.classes], [Float](repeating: 0, count: NetSpec.classes), "fc2b"))

        for p in paramInfo {
            variables.append(makeVariable(p.shape, data: p.data, name: p.name))
            shapes.append(p.shape)
        }
        reads = variables.enumerated().map { graph.read($0.element, name: "read\($0.offset)") }

        x = graph.placeholder(shape: nsShape([B, sampleSize, sampleSize, 3]), dataType: .float32, name: "x")
        y = graph.placeholder(shape: nsShape([B, NetSpec.classes]), dataType: .float32, name: "y")
        lr = graph.placeholder(shape: [1], dataType: .float32, name: "lr")

        let trainLogits = forward(training: true)
        evalLogits = forward(training: false)
        loss = graph.softMaxCrossEntropy(trainLogits, labels: y, axis: -1, reuctionType: .mean, name: "loss")

        let grads = graph.gradients(of: loss, with: reads, name: nil)
        let b1 = graph.constant(0.9, dataType: .float32), b2 = graph.constant(0.999, dataType: .float32)
        let ob1 = graph.constant(0.1, dataType: .float32), ob2 = graph.constant(0.001, dataType: .float32)
        let eps = graph.constant(1e-7, dataType: .float32)
        for (i, v) in variables.enumerated() {
            let g = grads[reads[i]]!
            let m = makeVariable(shapes[i], data: [Float](repeating: 0, count: shapes[i].reduce(1, *)), name: "m\(i)")
            let s = makeVariable(shapes[i], data: [Float](repeating: 0, count: shapes[i].reduce(1, *)), name: "s\(i)")
            let mRead = graph.read(m, name: nil), sRead = graph.read(s, name: nil)
            let mNew = graph.addition(graph.multiplication(b1, mRead, name: nil), graph.multiplication(ob1, g, name: nil), name: nil)
            let sNew = graph.addition(graph.multiplication(b2, sRead, name: nil), graph.multiplication(ob2, graph.square(with: g, name: nil), name: nil), name: nil)
            let denom = graph.addition(graph.squareRoot(with: sNew, name: nil), eps, name: nil)
            let step = graph.multiplication(lr, graph.division(mNew, denom, name: nil), name: nil)
            let pNew = graph.subtraction(reads[i], step, name: nil)
            updateOps.append(graph.assign(m, tensor: mNew, name: nil))
            updateOps.append(graph.assign(s, tensor: sNew, name: nil))
            updateOps.append(graph.assign(v, tensor: pNew, name: nil))
        }
    }

    private func forward(training: Bool) -> MPSGraphTensor {
        var t = x!
        let convDesc = MPSGraphConvolution2DOpDescriptor(
            strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1, groups: 1,
            paddingLeft: 1, paddingRight: 1, paddingTop: 1, paddingBottom: 1,
            paddingStyle: .explicit, dataLayout: .NHWC, weightsLayout: .HWIO)!
        let poolDesc = MPSGraphPooling2DOpDescriptor(
            kernelWidth: 2, kernelHeight: 2, strideInX: 2, strideInY: 2, paddingStyle: .explicit, dataLayout: .NHWC)!
        for l in 0..<4 {
            t = graph.convolution2D(t, weights: reads[2 * l], descriptor: convDesc, name: nil)
            t = graph.addition(t, reads[2 * l + 1], name: nil)
            t = graph.reLU(with: t, name: nil)
            t = graph.maxPooling2D(withSourceTensor: t, descriptor: poolDesc, name: nil)
        }
        t = graph.reshape(t, shape: nsShape([-1, NetSpec.flat]), name: nil)
        t = graph.matrixMultiplication(primary: t, secondary: reads[8], name: nil)
        t = graph.addition(t, reads[9], name: nil)
        t = graph.reLU(with: t, name: nil)
        if training { t = graph.dropout(t, rate: 0.3, name: nil) }
        t = graph.matrixMultiplication(primary: t, secondary: reads[10], name: nil)
        t = graph.addition(t, reads[11], name: nil)
        return t
    }

    private func normalized(_ ds: Dataset, indices: ArraySlice<Int>) -> [Float] {
        var out = [Float](repeating: 0, count: B * Dataset.imageBytes)
        for (k, idx) in indices.enumerated() {
            let base = idx * Dataset.imageBytes
            for j in 0..<Dataset.imageBytes { out[k * Dataset.imageBytes + j] = Float(ds.pixels[base + j]) / 255 - 0.5 }
        }
        return out
    }

    private func tensorData(_ values: [Float], shape: [Int]) -> MPSGraphTensorData {
        MPSGraphTensorData(device: device, data: values.withUnsafeBufferPointer { Data(buffer: $0) }, shape: nsShape(shape), dataType: .float32)
    }

    /// One pass over `ds` in random order; returns mean loss.
    func trainEpoch(_ ds: Dataset, learningRate: Float, rng: inout SplitMix64) -> Float {
        var order = Array(0..<ds.count)
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, rng.int(i + 1)) }
        var total: Float = 0
        var steps = 0
        var i = 0
        while i + B <= order.count {
            autoreleasepool {
            memoryGuard("step")
            let idx = order[i..<(i + B)]
            let xs = normalized(ds, indices: idx)
            var ys = [Float](repeating: 0, count: B * NetSpec.classes)
            for (k, j) in idx.enumerated() { ys[k * NetSpec.classes + Int(ds.labels[j])] = 1 }
            let out = graph.run(with: queue,
                feeds: [x: tensorData(xs, shape: [B, sampleSize, sampleSize, 3]), y: tensorData(ys, shape: [B, NetSpec.classes]), lr: tensorData([learningRate], shape: [1])],
                targetTensors: [loss], targetOperations: updateOps)
            var l: Float = 0
            out[loss]!.mpsndarray().readBytes(&l, strideBytes: nil)
            total += l
            steps += 1
            }
            i += B
        }
        return total / Float(max(1, steps))
    }

    /// Returns accuracy and the confusion matrix [true][pred].
    func evaluate(_ ds: Dataset) -> (accuracy: Double, confusion: [[Int]]) {
        var correct = 0
        var confusion = [[Int]](repeating: [Int](repeating: 0, count: NetSpec.classes), count: NetSpec.classes)
        var i = 0
        while i < ds.count {
            autoreleasepool {
            let n = min(B, ds.count - i)
            var idx = Array(i..<(i + n))
            while idx.count < B { idx.append(i) }
            let xs = normalized(ds, indices: idx[...])
            let out = graph.run(with: queue, feeds: [x: tensorData(xs, shape: [B, sampleSize, sampleSize, 3])], targetTensors: [evalLogits], targetOperations: nil)
            var logits = [Float](repeating: 0, count: B * NetSpec.classes)
            out[evalLogits]!.mpsndarray().readBytes(&logits, strideBytes: nil)
            for k in 0..<n {
                let row = logits[(k * NetSpec.classes)..<((k + 1) * NetSpec.classes)]
                let pred = row.enumerated().max { $0.element < $1.element }!.offset
                let truth = Int(ds.labels[i + k])
                confusion[truth][pred] += 1
                if pred == truth { correct += 1 }
            }
            i += n
            }
        }
        return (Double(correct) / Double(ds.count), confusion)
    }

    /// Weights as flat float arrays in parameter order (conv0w, conv0b, ..., fc2w, fc2b).
    func exportWeights() -> [[Float]] {
        let out = graph.run(with: queue, feeds: [:], targetTensors: reads, targetOperations: nil)
        return reads.enumerated().map { i, r in
            var buf = [Float](repeating: 0, count: shapes[i].reduce(1, *))
            out[r]!.mpsndarray().readBytes(&buf, strideBytes: nil)
            return buf
        }
    }
}

/// File format: "PNET" magic, UInt32 version(1), UInt32 tensor count, then per tensor UInt32 element count,
/// followed by all tensor data as little-endian Float16 in parameter order.
func writeWeights(_ tensors: [[Float]], to url: URL) throws {
    var data = Data("PNET".utf8)
    func put(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
    put(1)
    put(UInt32(tensors.count))
    for t in tensors { put(UInt32(t.count)) }
    for t in tensors {
        var h = t.map { Float16($0) }
        data.append(Data(bytes: &h, count: h.count * 2))
    }
    try data.write(to: url)
}

func trainCNN(lila: String, output: String, rounds: Int, perClass: Int, epochsPerRound: Int) throws {
    let sets = try trainingSetNames.map { try loadPieceSet(named: $0, lilaPieceDir: lila) }
    let held = try loadPieceSet(named: heldOutSetName, lilaPieceDir: lila)
    let trainRenderer = SampleRenderer(sets: sets, themes: { randomTheme(&$0) })
    let heldRenderer = SampleRenderer(sets: [held], themes: { _ in heldOutTheme })
    let t0 = Date()
    let heldSet = generateDataset(perClass: 150, seed: 777_001, renderer: heldRenderer, heldOut: held)
    let seenSet = generateDataset(perClass: 100, seed: 777_002, renderer: trainRenderer)
    print("mem \(Int(memoryGuard("evalsets"))) MB")
    print("eval sets generated in \(Int(Date().timeIntervalSince(t0)))s (held-out \(heldSet.count), seen \(seenSet.count))")

    let trainer = Trainer(seed: 42)
    var rng = SplitMix64(seed: 7)
    let totalEpochs = rounds * epochsPerRound
    var epoch = 0
    for round in 0..<rounds {
        let tg = Date()
        let ds = generateDataset(perClass: perClass, seed: UInt64(round + 1), renderer: trainRenderer)
        let genTime = Int(Date().timeIntervalSince(tg))
        var lastLoss: Float = 0
        for _ in 0..<epochsPerRound {
            let progress = Float(epoch) / Float(max(1, totalEpochs))
            let lr = 0.0015 * (0.5 * (1 + cos(.pi * progress))) + 0.00008
            lastLoss = trainer.trainEpoch(ds, learningRate: lr, rng: &rng)
            epoch += 1
        }
        print("mem after train \(Int(memoryGuard("train"))) MB")
        let seen = trainer.evaluate(seenSet).accuracy
        let heldAcc = trainer.evaluate(heldSet).accuracy
        print(String(format: "round %d/%d gen %ds loss %.4f seen-acc %.4f held-out-acc %.4f", round + 1, rounds, genTime, lastLoss, seen, heldAcc))
    }
    let final = trainer.evaluate(heldSet)
    let seenFinal = trainer.evaluate(seenSet)
    print("final seen accuracy \(seenFinal.accuracy)")
    for (i, row) in seenFinal.confusion.enumerated() { print("seen", classLabels[i].padding(toLength: 6, withPad: " ", startingAt: 0), row) }
    print("final held-out accuracy \(final.accuracy)")
    print("confusion (rows true, cols pred), labels: \(classLabels)")
    for (i, row) in final.confusion.enumerated() { print(classLabels[i].padding(toLength: 6, withPad: " ", startingAt: 0), row) }
    try writeWeights(trainer.exportWeights(), to: URL(fileURLWithPath: output))
    print("wrote \(output)")
}
