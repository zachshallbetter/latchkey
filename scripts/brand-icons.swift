// Regenerate native runtime icon alternatives and Safari's static default from the checked-in vector sources.
// Run through the shared build register: swift scripts/brand-icons.swift
import AppKit
import Foundation

enum IconError: Error { case missingSource(String), bitmap, context, encoding }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("App/Latchkey/Assets.xcassets")

func render(source: String, pixels: Int, dark: Bool, key: Bool) throws -> Data {
    let url = root.appendingPathComponent("App/Branding/" + source)
    guard let mark = NSImage(contentsOf: url) else { throw IconError.missingSource(source) }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw IconError.bitmap }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconError.context }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.18)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(white: dark ? 0.17 : 0.95, alpha: 1).setFill()
    tile.fill()
    NSShadow().set()
    NSColor(white: dark ? 0.4 : 0.78, alpha: 0.5).setStroke()
    tile.lineWidth = 1
    tile.stroke()
    let markHeight: CGFloat = 690
    let ratio = mark.size.width / max(mark.size.height, 1)
    let rect = NSRect(x: (1024 - markHeight * ratio) / 2, y: (1024 - markHeight) / 2,
                      width: markHeight * ratio, height: markHeight)
    if key {
        let tinted = NSImage(size: mark.size)
        tinted.lockFocus()
        mark.draw(in: NSRect(origin: .zero, size: mark.size))
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: mark.size).fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.draw(in: rect)
    } else {
        mark.draw(in: rect)
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconError.encoding }
    return data
}

for (name, source, key) in [("PistachioDockIcon", "pistachio.svg", false), ("KeyDockIcon", "logo.svg", true)] {
    let directory = assets.appendingPathComponent(name + ".imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for dark in [false, true] {
        try render(source: source, pixels: 1024, dark: dark, key: key)
            .write(to: directory.appendingPathComponent(dark ? "dark.png" : "light.png"))
    }
    let contents: [String: Any] = ["images": [
        ["idiom": "universal", "filename": "light.png"],
        ["idiom": "universal", "filename": "dark.png", "appearances": [["appearance": "luminosity", "value": "dark"]]]
    ], "info": ["version": 1, "author": "xcode"]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
}
for size in [48, 96, 128] {
    try render(source: "pistachio.svg", pixels: size, dark: false, key: false)
        .write(to: root.appendingPathComponent("App/Safari/Resources/icon-\(size).png"))
}
print("Rendered Key/Pistachio Dock alternatives and Safari icons from local vector sources.")
