#!/usr/bin/env swift
// Generates mac/ChessLens/Resources/Assets.xcassets/AppIcon.appiconset (all macOS sizes)
// plus previews. Usage: swift mac/scripts/gen-appicon.swift [preview-dir]
// Palette from Assets.xcassets (dark variants): sqL #B9C5BA, sqD #5F7A6D, bg #171D1B, gold #D8A53F.
import AppKit
import CoreGraphics
import Foundation

func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
let sqL = col(0xC4D0C5), sqD = col(0x5F7A6D)
let bgTop = col(0x26312E), bgBot = col(0x111715)
let gold = col(0xDDAE4C), ink = col(0x141A18), cream = col(0xF6F3E8)

func knightPath(in box: CGRect) -> CGPath {
    // 100x100 design space, y down, knight faces left.
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x / 100 * box.width, y: box.maxY - y / 100 * box.height)
    }
    p.move(to: pt(20, 90))
    p.addLine(to: pt(80, 90))
    p.addLine(to: pt(80, 80))
    p.addCurve(to: pt(56, 26), control1: pt(84, 60), control2: pt(76, 38))
    p.addLine(to: pt(58, 8))
    p.addLine(to: pt(44, 18))
    p.addCurve(to: pt(14, 54), control1: pt(34, 24), control2: pt(22, 40))
    p.addCurve(to: pt(18, 64), control1: pt(11, 58), control2: pt(13, 63))
    p.addCurve(to: pt(36, 55), control1: pt(25, 67), control2: pt(31, 60))
    p.addCurve(to: pt(36, 74), control1: pt(24, 66), control2: pt(26, 70))
    p.addCurve(to: pt(20, 90), control1: pt(28, 78), control2: pt(22, 82))
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> CGImage {
    let S = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let u = S / 1024
    ctx.scaleBy(x: u, y: u)
    // tile
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: col(0x000000, 0.35))
    ctx.setFillColor(bgBot); ctx.addPath(squircle); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [bgTop, bgBot] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // lens
    let c = CGPoint(x: 480, y: 548), R: CGFloat = 290
    // handle
    ctx.setLineCap(.round)
    ctx.setStrokeColor(gold); ctx.setLineWidth(86)
    ctx.move(to: CGPoint(x: c.x + R * 0.72, y: c.y - R * 0.72))
    ctx.addLine(to: CGPoint(x: 800, y: 228)); ctx.strokePath()
    // board inside lens
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)); ctx.clip()
    let b = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
    let h = b.width / 2
    for r in 0..<2 { for f in 0..<2 {
        ctx.setFillColor((r + f) % 2 == 0 ? sqL : sqD)
        ctx.fill(CGRect(x: b.minX + CGFloat(f) * h, y: b.maxY - CGFloat(r + 1) * h, width: h, height: h))
    } }
    ctx.restoreGState()
    // knight: dark body with cream halo
    let kb = CGRect(x: c.x - 175, y: c.y - 180, width: 350, height: 350)
    let kp = knightPath(in: kb)
    ctx.setLineJoin(.round)
    ctx.addPath(kp); ctx.setStrokeColor(cream); ctx.setLineWidth(46); ctx.strokePath()
    ctx.addPath(kp); ctx.setFillColor(ink); ctx.fillPath()
    // eye
    ctx.setFillColor(cream)
    ctx.fillEllipse(in: CGRect(x: kb.minX + 0.40 * 350 - 17, y: kb.maxY - 0.40 * 350 - 17, width: 34, height: 34))
    // ring
    ctx.setStrokeColor(gold); ctx.setLineWidth(62)
    ctx.strokeEllipse(in: CGRect(x: c.x - R - 6, y: c.y - R - 6, width: 2 * R + 12, height: 2 * R + 12))
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("ChessLens/Resources/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(px), set.appendingPathComponent(name).path)
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
if CommandLine.arguments.count > 1 {
    let d = CommandLine.arguments[1]
    writePNG(render(1024), d + "/preview-1024.png")
    writePNG(render(32), d + "/preview-32.png")
    writePNG(render(16), d + "/preview-16.png")
}
print("wrote \(set.path)")
