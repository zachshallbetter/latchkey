// Makes the artwork for Latchkey's installer package and disk image from the logo (App/Branding/logo.svg).
//
// Outputs:
//   packaging/pkg/resources/background.png, background-dark.png
//       Installer's lower-left art: the key, peeking in from the corner behind the step list (Distribution.xml,
//       alignment bottomleft, no scaling). 600 pixels at 144 dpi, so Installer draws it at 300 points.
//   packaging/dmg/background.tiff
//       The disk image window, 640×400 points with a 2x representation: the title, an arrow from Latchkey to
//       Applications, and a line on opening it without dragging. The blue is the mid-tone where Finder's black
//       (light mode) and white (dark mode) icon labels both reach 4.5:1 contrast.
//
// Usage: swift scripts/make-installer-art.swift   (AppKit only; no other dependencies)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
guard let logo = NSImage(contentsOf: root.appendingPathComponent("App/Branding/logo.svg")) else {
    FileHandle.standardError.write(Data("make-installer-art: can't read App/Branding/logo.svg\n".utf8))
    exit(1)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let brandBlue = color(0x1F7CF0)       // the logo's blue (site/logo.svg)
let brandBlueDark = color(0x4EA1FF)   // the site's accent in dark mode
let labelSafe = color(0x2D74D3)       // black text 4.55:1, white text 4.62:1
let deep = color(0x225EB0)

/// The logo tinted one colour (the SVG is a single fill).
func tintedLogo(_ tint: NSColor) -> NSImage {
    NSImage(size: logo.size, flipped: false) { rect in
        logo.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceIn)
        return true
    }
}

/// Draws into a bitmap of `width`×`height` pixels; the rep's size in points makes the context draw in points.
func bitmap(width: Int, height: Int, scale: CGFloat, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    draw(ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Installer's corner: 300×300 points, the key coming in from the bottom-left, fading toward the top and right so the
/// step labels above it stay readable.
func installerBackground(dark: Bool) -> NSBitmapImageRep {
    let side: CGFloat = 300
    return bitmap(width: 600, height: 600, scale: 2) { cg in
        let key = tintedLogo(dark ? brandBlueDark : brandBlue)
        let w: CGFloat = side * 0.92, h = w * logo.size.height / logo.size.width
        cg.saveGState()
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.translateBy(x: -side * 0.20, y: -side * 0.22)
        cg.rotate(by: 0.12)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0.22)
        shadow.shadowOffset = NSSize(width: 4, height: -8)
        shadow.shadowBlurRadius = 12
        shadow.set()
        key.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        cg.endTransparencyLayer()
        cg.restoreGState()
        // Fade: keep the lower-left, let the top and right go.
        let fade = NSGradient(colors: [NSColor.black.withAlphaComponent(dark ? 0.55 : 0.75), NSColor.black.withAlphaComponent(0)],
                              atLocations: [0.35, 1], colorSpace: .deviceRGB)!
        cg.setBlendMode(.destinationIn)
        fade.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: side * 0.85, y: side * 0.85), options: [.drawsBeforeStartingLocation])
    }
}

/// The disk image window, 640×400 points.
func dmgBackground(scale: CGFloat) -> NSBitmapImageRep {
    let W: CGFloat = 640, H: CGFloat = 400
    return bitmap(width: Int(W * scale), height: Int(H * scale), scale: scale) { cg in
        labelSafe.setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        // A large key in the lower-right corner, clear of the icons and their labels.
        let key = tintedLogo(deep)
        let kw: CGFloat = 190, kh = kw * logo.size.height / logo.size.width
        key.draw(in: NSRect(x: W - kw * 0.70, y: -kh * 0.16, width: kw, height: kh), from: .zero, operation: .sourceOver, fraction: 0.55)

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat) {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                                                        .paragraphStyle: p, .kern: size > 20 ? -0.4 : 0]
            let str = NSAttributedString(string: s, attributes: attrs)
            let height = str.size().height
            str.draw(in: NSRect(x: 0, y: H - top - height, width: W, height: height))
        }
        text("Secrets out of .env files.", size: 28, weight: .bold, alpha: 1, top: 34)
        text("Drag Latchkey to Applications.", size: 15, weight: .medium, alpha: 0.95, top: 76)

        // Arrow from Latchkey (x = 170) to Applications (x = 470), at icon height (y = 210 from the top).
        let y = H - 210, x0: CGFloat = 258, x1: CGFloat = 382
        NSColor.white.setStroke()
        NSColor.white.setFill()
        let line = NSBezierPath()
        line.lineWidth = 6
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: x0, y: y))
        line.line(to: NSPoint(x: x1 - 18, y: y))
        line.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x1, y: y))
        head.line(to: NSPoint(x: x1 - 24, y: y + 16))
        head.line(to: NSPoint(x: x1 - 24, y: y - 16))
        head.close()
        head.fill()

        text("Then open it from Applications: a short welcome sets up the rest.", size: 13, weight: .regular, alpha: 0.9, top: 340)
        _ = cg
    }
}

func png(_ rep: NSBitmapImageRep, _ path: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(path))
    print("wrote", path)
}

let pkg = "packaging/pkg/resources", dmg = "packaging/dmg"
try FileManager.default.createDirectory(at: root.appendingPathComponent(dmg), withIntermediateDirectories: true)
try png(installerBackground(dark: false), "\(pkg)/background.png")
try png(installerBackground(dark: true), "\(pkg)/background-dark.png")

// One TIFF holding both sizes, so Finder picks the 2x one on a Retina display.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("latchkey-art-\(getpid())")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let one = tmp.appendingPathComponent("bg.png"), two = tmp.appendingPathComponent("bg@2x.png")
try dmgBackground(scale: 1).representation(using: .png, properties: [:])!.write(to: one)
try dmgBackground(scale: 2).representation(using: .png, properties: [:])!.write(to: two)
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", one.path, two.path, "-out", root.appendingPathComponent("\(dmg)/background.tiff").path]
tiffutil.standardOutput = FileHandle.nullDevice
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { FileHandle.standardError.write(Data("tiffutil failed\n".utf8)); exit(1) }
print("wrote", "\(dmg)/background.tiff")
