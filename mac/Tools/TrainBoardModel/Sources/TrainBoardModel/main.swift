import AppKit
import Foundation

// Usage:
//   TrainBoardModel generate <lilaPieceDir> <datasetDir> <trainPerClass> <testPerClass>
//   TrainBoardModel sheet    <datasetDir>/train <out.png>
//   TrainBoardModel set-sheet <lilaPieceDir> <out.png>          (piece set contact sheet)
//   TrainBoardModel train-cnn <lilaPieceDir> <PieceNet.bin> <rounds> <perClass> <epochsPerRound>
//   TrainBoardModel export-heldout-pieces <lilaPieceDir> <outDir>   (fixtures for the Swift tests)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: see main.swift header") }

func generate(lila: String, out: String, trainPerClass: Int, testPerClass: Int) throws {
    let fm = FileManager.default
    try? fm.removeItem(atPath: out)
    let sets = try trainingSetNames.map { try loadPieceSet(named: $0, lilaPieceDir: lila) }
    let held = try loadPieceSet(named: heldOutSetName, lilaPieceDir: lila)
    print("loaded \(sets.count) training piece sets + held-out '\(held.name)'")

    let trainRenderer = SampleRenderer(sets: sets, themes: { randomTheme(&$0) })
    for (li, label) in classLabels.enumerated() {
        let dir = "\(out)/train/\(label)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var rng = SplitMix64(seed: UInt64(1000 + li))
        for n in 0..<trainPerClass {
            let img = trainRenderer.render(label: li, rng: &rng)
            try writePNG(img, to: URL(fileURLWithPath: "\(dir)/\(n).png"))
        }
        let hdir = "\(out)/test-heldout/\(label)"
        try fm.createDirectory(atPath: hdir, withIntermediateDirectories: true)
        var hrng = SplitMix64(seed: UInt64(900_000 + li))
        let heldRenderer = SampleRenderer(sets: [held], themes: { _ in heldOutTheme })
        for n in 0..<testPerClass {
            // Half with the held-out theme, half with random seen themes: isolates the piece-set generalisation.
            let img = heldRenderer.render(label: li, rng: &hrng, pieceSet: held, theme: n % 2 == 0 ? heldOutTheme : randomTheme(&hrng))
            try writePNG(img, to: URL(fileURLWithPath: "\(hdir)/\(n).png"))
        }
        print("generated \(label)")
    }
}

func sheet(dir: String, out: String) throws {
    let cols = 13, rows = 8, cell = 80
    let ctx = makeContext(cols * cell, rows * cell)
    for (ci, label) in classLabels.enumerated() {
        for r in 0..<rows {
            let url = URL(fileURLWithPath: "\(dir)/\(label)/\(r * 7).png")
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            ctx.draw(img, in: CGRect(x: ci * cell, y: (rows - 1 - r) * cell, width: cell, height: cell))
        }
    }
    try writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: out))
}

switch args[1] {
case "generate":
    try generate(lila: args[2], out: args[3], trainPerClass: Int(args[4])!, testPerClass: Int(args[5])!)
case "sheet":
    try sheet(dir: args[2], out: args[3])
case "export-heldout-pieces":
    let held = try loadPieceSet(named: heldOutSetName, lilaPieceDir: args[2], size: 128)
    try FileManager.default.createDirectory(atPath: args[3], withIntermediateDirectories: true)
    for code in pieceCodes { try writePNG(held.images[code]!, to: URL(fileURLWithPath: "\(args[3])/\(code).png")) }
case "set-sheet":
    try setSheet(lila: args[2], out: args[3])
case "train-cnn":
    try trainCNN(lila: args[2], output: args[3], rounds: Int(args[4])!, perClass: Int(args[5])!, epochsPerRound: Int(args[6])!)
default:
    fail("unknown command \(args[1])")
}
