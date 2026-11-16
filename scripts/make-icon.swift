// Draws the app icon and writes a 1024px PNG. Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Background tile, following the macOS icon grid (824pt tile on a 1024pt canvas).
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0x2A1A5E).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x8B5CF6), ending: color(0x3B1F8F))!.draw(in: tile, angle: -90)

// Four white keys with three black keys between them.
let keyWidth: CGFloat = 116, gap: CGFloat = 12, left: CGFloat = 262, bottom: CGFloat = 300, height: CGFloat = 424
color(0xFFFFFF).setFill()
for index in 0..<4 {
    let x = left + CGFloat(index) * (keyWidth + gap)
    NSBezierPath(roundedRect: NSRect(x: x, y: bottom, width: keyWidth, height: height), xRadius: 24, yRadius: 24).fill()
}
color(0x1E1240).setFill()
for index in 1..<4 {
    let center = left + CGFloat(index) * (keyWidth + gap) - gap / 2
    let rect = NSRect(x: center - 38, y: bottom + height - 250, width: 76, height: 250)
    NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
