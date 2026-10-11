// Draws the app icon: the macOS AppIcon.icns plus PNG icons for the web app (home screen / Android).
// Usage: swift tools/make_icon.swift   (run from the repository root)
import AppKit
import CoreGraphics

let root = FileManager.default.currentDirectoryPath

/// - Parameter macStyle: rounded square with transparent margin (macOS); otherwise full-bleed (masked by iOS/Android).
func drawIcon(size: Int, macStyle: Bool) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: s / 1024, y: -s / 1024) // draw in a 1024 grid, top-left origin

    let body = macStyle ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: macStyle ? 185 : 0, cornerHeight: macStyle ? 185 : 0, transform: nil)
    if macStyle {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(bodyPath)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(red: 1.0, green: 0.50, blue: 0.27, alpha: 1),
        CGColor(red: 0.78, green: 0.20, blue: 0.11, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

    // Content area (the safe zone for masked icons is smaller).
    let c = macStyle ? body.insetBy(dx: 70, dy: 70) : body.insetBy(dx: 170, dy: 170)
    let u = c.width / 684 // unit relative to the mac content box

    // Projector screen with a slide on it.
    let screen = CGRect(x: c.minX + 20 * u, y: c.minY + 10 * u, width: 644 * u, height: 360 * u)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 40 * u, cornerHeight: 40 * u, transform: nil))
    ctx.fillPath()
    let accent = CGColor(red: 0.85, green: 0.27, blue: 0.13, alpha: 1)
    ctx.setFillColor(accent)
    ctx.fill(CGRect(x: screen.minX + 60 * u, y: screen.minY + 52 * u, width: 280 * u, height: 38 * u))
    let barBase = screen.maxY - 50 * u
    for (i, h) in [100.0, 170, 135].enumerated() {
        ctx.fill(CGRect(x: screen.minX + (62 + Double(i) * 82) * u, y: barBase - h * u, width: 56 * u, height: h * u))
    }
    ctx.setFillColor(CGColor(red: 0.85, green: 0.27, blue: 0.13, alpha: 0.35))
    for (i, w) in [170.0, 130, 150].enumerated() {
        ctx.fill(CGRect(x: screen.minX + 400 * u, y: screen.minY + (150 + Double(i) * 50) * u, width: w * u, height: 26 * u))
    }

    // Remote (phone) below the screen, with signal arcs towards it.
    let phone = CGRect(x: c.midX - 72 * u, y: c.minY + 478 * u, width: 144 * u, height: 206 * u)
    ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 36 * u, cornerHeight: 36 * u, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1))
    ctx.addPath(CGPath(roundedRect: phone.insetBy(dx: 16 * u, dy: 20 * u), cornerWidth: 18 * u, cornerHeight: 18 * u, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)) // "next" arrow on the phone
    let cx = phone.midX, cy = phone.midY
    ctx.move(to: CGPoint(x: cx - 22 * u, y: cy - 38 * u))
    ctx.addLine(to: CGPoint(x: cx + 30 * u, y: cy))
    ctx.addLine(to: CGPoint(x: cx - 22 * u, y: cy + 38 * u))
    ctx.closePath()
    ctx.fillPath()

    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineWidth(22 * u)
    let origin = CGPoint(x: phone.midX, y: phone.minY - 8 * u)
    for (i, r) in [34.0, 70].enumerated() {
        ctx.setAlpha(1 - CGFloat(i) * 0.3)
        ctx.addArc(center: origin, radius: r * u, startAngle: .pi * 1.25, endAngle: .pi * 1.75, clockwise: false)
        ctx.strokePath()
    }
    ctx.setAlpha(1)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// macOS .icns
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(size: base, macStyle: true), "\(iconset)/icon_\(base)x\(base).png")
    writePNG(drawIcon(size: base * 2, macStyle: true), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
let icns = "\(root)/mac-helper/Resources/AppIcon.icns"
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", icns]
try! p.run()
p.waitUntilExit()
print("wrote", icns)

// Web app icons (full-bleed; iOS and Android apply their own mask).
for size in [180, 192, 512] {
    writePNG(drawIcon(size: size, macStyle: false), "\(root)/docs/icon-\(size).png")
}
writePNG(drawIcon(size: 64, macStyle: true), "\(root)/docs/favicon.png")
writePNG(drawIcon(size: 1024, macStyle: true), NSTemporaryDirectory() + "pptremote-icon-preview.png")
print("wrote web icons")
