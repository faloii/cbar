#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — a warm cream rounded square with an
// orange-to-green gradient "C", a 3-bar ascending mini bar-chart in its
// opening, and a small sparkle accent. Detail is simplified at 16/32px (the
// gradient/bars/sparkle smear into noise below that; Apple's HIG recommends
// simplifying small-size icon renditions rather than shrinking the same art).
// Run: swift Scripts/make_icon.swift
import AppKit

let root = FileManager.default.currentDirectoryPath
let iconsetDir = "\(root)/build/AppIcon.iconset"
let outIcns = "\(root)/Resources/AppIcon.icns"

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: "\(root)/Resources", withIntermediateDirectories: true)

func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }

/// A 4-pointed sparkle/twinkle shape (concave diamond), centered at the origin
/// with point radius `r`, as a reusable path.
func sparklePath(center: NSPoint, r: CGFloat) -> NSBezierPath {
    let k = r * 0.18
    let p = NSBezierPath()
    p.move(to: NSPoint(x: center.x, y: center.y + r))
    p.curve(to: NSPoint(x: center.x + r, y: center.y),
            controlPoint1: NSPoint(x: center.x + k, y: center.y + k),
            controlPoint2: NSPoint(x: center.x + k, y: center.y + k))
    p.curve(to: NSPoint(x: center.x, y: center.y - r),
            controlPoint1: NSPoint(x: center.x + k, y: center.y - k),
            controlPoint2: NSPoint(x: center.x + k, y: center.y - k))
    p.curve(to: NSPoint(x: center.x - r, y: center.y),
            controlPoint1: NSPoint(x: center.x - k, y: center.y - k),
            controlPoint2: NSPoint(x: center.x - k, y: center.y - k))
    p.curve(to: NSPoint(x: center.x, y: center.y + r),
            controlPoint1: NSPoint(x: center.x - k, y: center.y + k),
            controlPoint2: NSPoint(x: center.x - k, y: center.y + k))
    p.close()
    return p
}

func render(_ px: Int, simplified: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let cg = nsCtx.cgContext

    let s  = CGFloat(px)
    let cx = s / 2, cy = s / 2
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    let orange = NSColor(srgbRed: 0.93, green: 0.56, blue: 0.16, alpha: 1)
    let green  = NSColor(srgbRed: 0.20, green: 0.62, blue: 0.35, alpha: 1)
    let gold   = NSColor(srgbRed: 0.96, green: 0.75, blue: 0.25, alpha: 1)
    let barGreen = NSColor(srgbRed: 0.47, green: 0.74, blue: 0.35, alpha: 1)

    // Warm cream background, clipped to the standard macOS rounded-square shape.
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
    bg.addClip()
    NSColor(srgbRed: 0.99, green: 0.965, blue: 0.925, alpha: 1).setFill()
    rect.fill()

    // "C" arc, orange→green top-to-bottom gradient. Built by converting the
    // stroked outline into a fillable region (CGContext's
    // replacePathWithStrokedPath), then filling that region with a linear
    // gradient — NSBezierPath can't stroke with a gradient directly.
    let arcR     = s * 0.27
    let arcWidth = s * (simplified ? 0.17 : 0.155)
    let startDeg: CGFloat = 58, endDeg: CGFloat = 302
    let arcPath = CGMutablePath()
    arcPath.addArc(center: CGPoint(x: cx, y: cy), radius: arcR,
                   startAngle: rad(startDeg), endAngle: rad(endDeg), clockwise: false)
    cg.saveGState()
    cg.addPath(arcPath)
    cg.setLineWidth(arcWidth)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.replacePathWithStrokedPath()
    cg.clip()
    // 4-stop gradient (rather than a plain 2-stop) so the upper arm stays solidly
    // orange and the lower arm solidly green, with the transition confined to the
    // middle — a plain top→bottom fade turns muddy right where it crosses the
    // thick rounded terminal caps.
    let cGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [orange.cgColor, orange.cgColor, green.cgColor, green.cgColor] as CFArray,
                               locations: [0, 0.4, 0.7, 1])!
    cg.drawLinearGradient(cGradient,
                          start: CGPoint(x: cx, y: cy + arcR),
                          end: CGPoint(x: cx, y: cy - arcR),
                          options: [])
    cg.restoreGState()

    if !simplified {
        // Ascending 3-bar mini chart, sitting in the C's opening, comfortably
        // clear of the arc terminals above and below.
        let barW: CGFloat = s * 0.08
        let gap: CGFloat = s * 0.04
        let baseY = cy - s * 0.09
        let heights: [CGFloat] = [s * 0.14, s * 0.205, s * 0.265]
        let colors = [barGreen, gold, orange]
        let totalW = barW * 3 + gap * 2
        let startX = cx + arcR * 0.02 - totalW / 2
        for i in 0..<3 {
            let x = startX + CGFloat(i) * (barW + gap)
            let barRect = NSRect(x: x, y: baseY, width: barW, height: heights[i])
            let bar = NSBezierPath(roundedRect: barRect, xRadius: barW * 0.35, yRadius: barW * 0.35)
            colors[i].setFill()
            bar.fill()
        }

        // Sparkle accent, clearly separated above and right of the bars/terminal.
        let sparkleCenter = NSPoint(x: cx + arcR * 1.1, y: cy + arcR * 1.0)
        orange.setFill()
        sparklePath(center: sparkleCenter, r: s * 0.07).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    let simplified = base <= 32
    let rep1 = render(base, simplified: simplified)
    let data1 = rep1.representation(using: .png, properties: [:])!
    try! data1.write(to: URL(fileURLWithPath: "\(iconsetDir)/icon_\(base)x\(base).png"))
    let rep2 = render(base * 2, simplified: simplified)
    let data2 = rep2.representation(using: .png, properties: [:])!
    try! data2.write(to: URL(fileURLWithPath: "\(iconsetDir)/icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", outIcns]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ wrote \(outIcns)" : "✗ iconutil failed (\(task.terminationStatus))")
