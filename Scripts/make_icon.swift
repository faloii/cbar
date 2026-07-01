#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — a bold white "C" lettermark on a deep navy
// rounded square, with a single coral accent dot in the C's opening (a "live
// status" motif fitting a usage monitor). Kept deliberately simple — legible
// down to 16px, where fine detail (e.g. multiple bars) just smears into noise.
// Run: swift Scripts/make_icon.swift
import AppKit

let root = FileManager.default.currentDirectoryPath
let iconsetDir = "\(root)/build/AppIcon.iconset"
let outIcns = "\(root)/Resources/AppIcon.icns"

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: "\(root)/Resources", withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s  = CGFloat(px)
    let cx = s / 2, cy = s / 2
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let coral = NSColor(srgbRed: 0.97, green: 0.49, blue: 0.32, alpha: 1)

    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
    bg.addClip()

    // Deep navy, diagonal gradient for more depth than a flat vertical fade.
    NSGradient(
        starting: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.27, alpha: 1),
        ending:   NSColor(srgbRed: 0.045, green: 0.05, blue: 0.09, alpha: 1))!
        .draw(in: rect, angle: -55)

    // Soft warm glow behind the mark, tying the accent color into the background
    // without adding visual noise at small sizes.
    if let glow = NSGradient(starting: coral.withAlphaComponent(0.16), ending: coral.withAlphaComponent(0)) {
        glow.draw(fromCenter: NSPoint(x: cx, y: cy), radius: 0,
                  toCenter: NSPoint(x: cx, y: cy), radius: s * 0.42, options: [])
    }

    // Bold white "C" arc.
    // In AppKit lower-left-origin coords: 0°=right, 90°=up (standard math).
    // CCW from ~50° to ~310° traces through top/left/bottom — the C opens to the right.
    let arcR     = s * 0.27    // radius of arc centre-line
    let arcWidth = s * 0.155   // thick stroke — reads clean down to 16px
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: cx, y: cy),
                  radius: arcR,
                  startAngle: 50,
                  endAngle: 310,
                  clockwise: false)
    arc.lineWidth    = arcWidth
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    // Single coral accent dot, sitting in the C's opening — a "live status" read
    // that stays crisp at every size, unlike fine multi-bar detail.
    let dotR = s * 0.085
    let dot = NSRect(x: cx + arcR * 0.62 - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2)
    coral.setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ name: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
}

for base in [16, 32, 128, 256, 512] {
    write(render(base),     "icon_\(base)x\(base).png")
    write(render(base * 2), "icon_\(base)x\(base)@2x.png")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", outIcns]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ wrote \(outIcns)" : "✗ iconutil failed (\(task.terminationStatus))")
