import AppKit

// Placeholder BerryDB app icon: macOS-blue gradient squircle + white database
// glyph (the same SF Symbol the sidebar uses). Clearly a placeholder — meant to
// be replaced by real art. Renders a 1024×1024 PNG at exact pixel size.

let px = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)
let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Rounded-rect (macOS icon corner ≈ 22.37% of the side).
let radius = size * 0.2237
let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
clip.addClip()

// Vertical macOS-blue gradient (#0A84FF → #0050D6).
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1),
    NSColor(srgbRed: 0.0, green: 0.314, blue: 0.839, alpha: 1),
])!
gradient.draw(in: rect, angle: -90)

// White database glyph, centered.
let config = NSImage.SymbolConfiguration(pointSize: 540, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    symbol.draw(in: NSRect(origin: origin, size: s))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! png.write(to: out)
print("wrote \(out.path) (\(png.count) bytes)")
