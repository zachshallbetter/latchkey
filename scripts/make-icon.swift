// Draws the app icon from the logo glyph: swift scripts/make-icon.swift App/Branding/key.svg OUT.png
// The glyph is Font Awesome Pro (commercial license); see the comment inside the SVG.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let glyph = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift GLYPH.svg OUT.png\n".utf8))
    exit(64)
}
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)   // 1 point = 1 pixel, so the output is exactly 1024 wide

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let size = CGFloat(px)

// macOS icon grid: an 824-point tile centred in the 1024 canvas, with room for the shadow.
let tile = NSRect(x: 100, y: 100, width: size - 200, height: size - 200)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.62, blue: 0.56, alpha: 1),
                    NSColor(srgbRed: 0.13, green: 0.29, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: -60)

// The glyph in white. It fills about 77% of its own 640 box, so 640 points reads well on the tile.
let side: CGFloat = 640
let white = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
    glyph.draw(in: r)
    NSColor.white.set()
    r.fill(using: .sourceAtop)
    return true
}
white.draw(in: NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
