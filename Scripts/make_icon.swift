#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — a white "sparkle" on a coral rounded square,
// matching ClaudeBar's menu-bar motif. Run: swift Scripts/make_icon.swift
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

    let s = CGFloat(px)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // Coral rounded-square background with a vertical gradient (macOS corner ≈ 22%).
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
    bg.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.91, green: 0.58, blue: 0.45, alpha: 1),
               ending:   NSColor(srgbRed: 0.76, green: 0.37, blue: 0.23, alpha: 1))!
        .draw(in: rect, angle: -90)

    // Four-pointed sparkle in white, centered.
    let cx = rect.midX, cy = rect.midY
    let R = s * 0.32          // point radius
    let k = R * 0.16          // concavity (smaller = sharper points)
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx, y: cy + R))
    p.curve(to: NSPoint(x: cx + R, y: cy), controlPoint1: NSPoint(x: cx + k, y: cy + k), controlPoint2: NSPoint(x: cx + k, y: cy + k))
    p.curve(to: NSPoint(x: cx, y: cy - R), controlPoint1: NSPoint(x: cx + k, y: cy - k), controlPoint2: NSPoint(x: cx + k, y: cy - k))
    p.curve(to: NSPoint(x: cx - R, y: cy), controlPoint1: NSPoint(x: cx - k, y: cy - k), controlPoint2: NSPoint(x: cx - k, y: cy - k))
    p.curve(to: NSPoint(x: cx, y: cy + R), controlPoint1: NSPoint(x: cx - k, y: cy + k), controlPoint2: NSPoint(x: cx - k, y: cy + k))
    p.close()
    NSColor.white.setFill()
    p.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ name: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
}

// Required iconset members.
for base in [16, 32, 128, 256, 512] {
    write(render(base),     "icon_\(base)x\(base).png")
    write(render(base * 2), "icon_\(base)x\(base)@2x.png")
}

// Compile to .icns.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", outIcns]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ wrote \(outIcns)" : "✗ iconutil failed (\(task.terminationStatus))")
