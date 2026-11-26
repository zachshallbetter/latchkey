// Composes an App Store screenshot from Pistachio's off-screen snapshots: the window (whose sidebar column doesn't
// render off screen), the sidebar drawn on its own, and optionally a panel shown over the window. With --title the
// window is set below a caption (and optional --subtitle). Output is an opaque 2880 × 1800 JPEG, the size and format
// App Store Connect takes for Mac screenshots.
//
//   swift scripts/compose-screenshot.swift [--title T [--subtitle S]] out.jpg window.png sidebar.png [panel.png]
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
let title = option("--title"), subtitle = option("--subtitle")
guard args.count >= 3, let window = NSImage(contentsOfFile: args[1]), let sidebar = NSImage(contentsOfFile: args[2]) else {
    FileHandle.standardError.write("usage: compose-screenshot.swift [--title T [--subtitle S]] out.jpg window.png sidebar.png [panel.png]\n".data(using: .utf8)!)
    exit(64)
}
let panel = args.count > 3 ? NSImage(contentsOfFile: args[3]) : nil
let size = NSSize(width: 2880, height: 1800)
func pixels(_ image: NSImage) -> NSSize {
    let rep = image.representations.first
    return NSSize(width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
}
func canvas(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2880, pixelsHigh: 1800, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let app = canvas {
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
}

var output = app
if let title {
    // Caption above the window, which is scaled down and runs off the bottom edge.
    let appImage = NSImage(size: size)
    appImage.addRepresentation(app)
    output = canvas {
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.11, alpha: 1),
                   ending: NSColor(calibratedWhite: 0.07, alpha: 1))!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 112, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: centered,
            .kern: -1.5,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 52, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.68), .paragraphStyle: centered,
        ]
        (title as NSString).draw(in: NSRect(x: 120, y: size.height - 250, width: size.width - 240, height: 150),
                                 withAttributes: titleAttributes)
        if let subtitle {
            (subtitle as NSString).draw(in: NSRect(x: 120, y: size.height - 340, width: size.width - 240, height: 80),
                                        withAttributes: subtitleAttributes)
        }
        let scale: CGFloat = 0.8
        let frame = NSRect(x: (size.width - size.width * scale) / 2, y: -60, width: size.width * scale,
                           height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 80
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
        shadow.set()
        let outline = NSBezierPath(roundedRect: frame, xRadius: 28, yRadius: 28)
        NSColor.black.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        appImage.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        outline.lineWidth = 2
        outline.stroke()
    }
}
let jpeg = output.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!
try! jpeg.write(to: URL(fileURLWithPath: args[0]))
