#!/usr/bin/env swift
// Renders the approved M0 app-icon concept A ("The Ferry", docs/DESIGN.md)
// into Ferry/Assets.xcassets/AppIcon.appiconset/.
// Development icon only — the polished 1024px master is scheduled for M17.
//
// Usage: swift tools/generate-appicon.swift

import AppKit

let outputDir = URL(fileURLWithPath: "Ferry/Assets.xcassets/AppIcon.appiconset")

/// Draws concept A at an arbitrary canvas size. Geometry mirrors
/// docs/design/icon-concept-a.svg (viewBox 0 0 120 120), placed in a
/// rounded-rect "squircle" that fills ~80% of the canvas per the macOS
/// icon grid, on a transparent background.
func drawIcon(canvas: CGFloat, into ctx: CGContext) {
    let content = canvas * 0.805                     // 824/1024 per Apple's grid
    let origin = (canvas - content) / 2
    let rect = CGRect(x: origin, y: origin, width: content, height: content)
    let radius = content * 0.2237

    // Squircle clip + sea gradient (top #1A94B5 → bottom #0A4A68)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0x1A/255.0, green: 0x94/255.0, blue: 0xB5/255.0, alpha: 1),
        CGColor(red: 0x0A/255.0, green: 0x4A/255.0, blue: 0x68/255.0, alpha: 1)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    // CG origin is bottom-left; gradient runs top → bottom.
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: canvas / 2, y: origin + content),
                           end: CGPoint(x: canvas / 2, y: origin),
                           options: [])

    // Map SVG coordinates (y down, 0–120) into the content rect (y up).
    let s = content / 120
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin + x * s, y: origin + (120 - y) * s)
    }
    func fillRoundedRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, color: CGColor) {
        let p = pt(x, y + h) // SVG top-left → CG bottom-left of the rect
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: CGRect(x: p.x, y: p.y, width: w * s, height: h * s),
                           cornerWidth: r * s, cornerHeight: r * s, transform: nil))
        ctx.fillPath()
    }

    let white = CGColor(gray: 1, alpha: 1)
    let windowBlue = CGColor(red: 0x0D/255.0, green: 0x64/255.0, blue: 0x84/255.0, alpha: 1)

    // Upper cabin, lower cabin
    fillRoundedRect(x: 44, y: 32, w: 32, h: 12, r: 3, color: white)
    fillRoundedRect(x: 36, y: 47, w: 48, h: 15, r: 3, color: white)

    // Portholes (skip below 64px — they turn to noise, matching the 32px mock)
    if canvas >= 64 {
        ctx.setFillColor(windowBlue)
        for cx in [46.0, 60.0, 74.0] {
            let c = pt(cx, 54.5)
            let r = 3.2 * s
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }

    // Hull: M27 66 h66 l-11 17 h-44 z
    ctx.setFillColor(white)
    ctx.move(to: pt(27, 66))
    ctx.addLine(to: pt(93, 66))
    ctx.addLine(to: pt(82, 83))
    ctx.addLine(to: pt(38, 83))
    ctx.closePath()
    ctx.fillPath()

    // Waves: M20 95 q8 -7 16 0, repeated ×5
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
    ctx.setLineWidth(4.5 * s)
    ctx.setLineCap(.round)
    ctx.move(to: pt(20, 95))
    var x: CGFloat = 20
    for _ in 0..<5 {
        ctx.addQuadCurve(to: pt(x + 16, 95), control: pt(x + 8, 88))
        x += 16
    }
    ctx.strokePath()
}

func renderPNG(pixels: Int, filename: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    drawIcon(canvas: CGFloat(pixels), into: ctx)
    let url = outputDir.appendingPathComponent(filename)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    renderPNG(pixels: pixels, filename: "icon_\(pixels).png")
}
