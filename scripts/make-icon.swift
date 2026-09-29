// Renders the Zombieport logo: a network port with crossed-out eyes.
// Usage: swift scripts/make-icon.swift
// Writes Resources/AppIcon.icns and docs/logo.png.
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Draws the logo into a 1024 x 1024 canvas with a top-left origin.
func drawLogo() {
    // Background: macOS icon grid content area (824 pt) with a green gradient.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: color(0x46E08F), ending: color(0x0B7A4B))!.draw(in: bg, angle: 90)

    // Port body with the latch notch below it.
    let face = color(0xF3FFF7)
    face.setFill()
    NSBezierPath(roundedRect: NSRect(x: 262, y: 290, width: 500, height: 370), xRadius: 56, yRadius: 56).fill()
    NSBezierPath(roundedRect: NSRect(x: 422, y: 620, width: 180, height: 110), xRadius: 24, yRadius: 24).fill()

    // Crossed-out eyes and a stitched mouth.
    let ink = color(0x0B5A38)
    ink.setStroke()
    for cx in [402.0, 622.0] {
        let eye = NSBezierPath()
        eye.lineWidth = 34
        eye.lineCapStyle = .round
        eye.move(to: NSPoint(x: cx - 48, y: 402)); eye.line(to: NSPoint(x: cx + 48, y: 498))
        eye.move(to: NSPoint(x: cx - 48, y: 498)); eye.line(to: NSPoint(x: cx + 48, y: 402))
        eye.stroke()
    }
    let mouth = NSBezierPath()
    mouth.lineWidth = 24
    mouth.lineCapStyle = .round
    mouth.move(to: NSPoint(x: 430, y: 580)); mouth.line(to: NSPoint(x: 594, y: 580))
    for x in [466.0, 512.0, 558.0] {
        mouth.move(to: NSPoint(x: x, y: 558)); mouth.line(to: NSPoint(x: x, y: 602))
    }
    mouth.stroke()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let scale = CGFloat(size) / 1024
    // Flip so the drawing code can use a top-left origin.
    ctx.cgContext.translateBy(x: 0, y: CGFloat(size))
    ctx.cgContext.scaleBy(x: scale, y: -scale)
    drawLogo()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try! fm.createDirectory(atPath: "docs", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try! png(size: 512).write(to: URL(fileURLWithPath: "docs/logo.png"))
print("Wrote Resources/AppIcon.icns and docs/logo.png")
