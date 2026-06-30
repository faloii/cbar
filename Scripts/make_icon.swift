#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — a bold white "C" lettermark on a deep navy
// rounded square, with three coral activity bars inside the C opening.
// Represents "C" (Claude/CBar) + usage monitoring at a glance.
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

    // Deep navy background with a subtle blue-tinted gradient (premium, dark).
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
    bg.addClip()
    NSGradient(
        starting: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.20, alpha: 1),
        ending:   NSColor(srgbRed: 0.06, green: 0.07, blue: 0.14, alpha: 1))!
        .draw(in: rect, angle: -90)

    // Bold white "C" arc.
    // In AppKit lower-left-origin coords: 0°=right, 90°=up (standard math).
    // CCW from 45° to 315° traces through top/left/bottom — the C opens to the right.
    let arcR     = s * 0.265   // radius of arc centre-line
    let arcWidth = s * 0.13    // stroke thickness — fat, readable at 16px
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: cx, y: cy),
                  radius: arcR,
                  startAngle: 42,
                  endAngle: 318,
                  clockwise: false)
    arc.lineWidth    = arcWidth
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    // Three coral activity bars inside the C opening (right side).
    // Heights encode a "rising" usage bar — taller middle bar, like a volume icon.
    let coral   = NSColor(srgbRed: 0.95, green: 0.50, blue: 0.35, alpha: 1)
    let barW    = s * 0.048
    let spacing = s * 0.072
    let maxH    = s * 0.20
    let heights: [CGFloat] = [maxH * 0.55, maxH, maxH * 0.55]
    let totalW  = barW * CGFloat(heights.count) + spacing * CGFloat(heights.count - 1)
    let barsX   = cx + arcR * 0.60 - totalW / 2   // sit in the C opening
    let baseY   = cy - maxH / 2

    for (i, h) in heights.enumerated() {
        let x = barsX + CGFloat(i) * (barW + spacing)
        let barRect = NSRect(x: x, y: baseY, width: barW, height: h)
        let bar = NSBezierPath(roundedRect: barRect, xRadius: barW * 0.4, yRadius: barW * 0.4)
        coral.setFill()
        bar.fill()
    }

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
