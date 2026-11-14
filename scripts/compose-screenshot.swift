// Composes an App Store screenshot from Latchkey's off-screen snapshots: the window (whose sidebar column doesn't
// render off screen), the sidebar drawn on its own, and optionally a panel shown over the window. Output is an opaque
// 2880 × 1800 JPEG, the size and format App Store Connect takes for Mac screenshots.
//
//   swift scripts/compose-screenshot.swift out.jpg window.png sidebar.png [panel.png]
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let window = NSImage(contentsOfFile: args[2]), let sidebar = NSImage(contentsOfFile: args[3]) else {
    FileHandle.standardError.write("usage: compose-screenshot.swift out.jpg window.png sidebar.png [panel.png]\n".data(using: .utf8)!)
    exit(64)
}
let panel = args.count > 4 ? NSImage(contentsOfFile: args[4]) : nil
let size = NSSize(width: 2880, height: 1800)
func pixels(_ image: NSImage) -> NSSize {
    let rep = image.representations.first
    return NSSize(width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2880, pixelsHigh: 1800, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
window.draw(in: NSRect(origin: .zero, size: size))
// The sidebar column: 250 points (500 pixels) wide, from the top.
// Render it with `--part sidebar --height 900` so it fills the column.
let sidebarWidth: CGFloat = 500
sidebar.draw(in: NSRect(x: 0, y: 0, width: sidebarWidth, height: size.height))
NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
NSRect(x: sidebarWidth - 1, y: 0, width: 1, height: size.height).fill()
if let panel {
    NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
    NSRect(origin: .zero, size: size).fill(using: .sourceOver)
    let pp = pixels(panel)
    let rect = NSRect(x: (size.width - pp.width) / 2, y: (size.height - pp.height) / 2, width: pp.width, height: pp.height)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 60
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.6)
    shadow.set()
    NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).addClip()
    panel.draw(in: rect)
}
NSGraphicsContext.restoreGraphicsState()
let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!
try! jpeg.write(to: URL(fileURLWithPath: args[1]))
