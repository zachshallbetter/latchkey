import LatchkeyCore
import SwiftUI

// The pieces every window and sheet is built from: a tinted icon tile, a sheet's header and footer, a card of rows, and
// a sidebar row. Plain system backgrounds throughout; colour comes from the tiles and the selection.

/// A rounded square in a colour, with a symbol on it.
struct IconTile: View {
    let symbol: String
    var tint: Color = .blue
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
    }
}

/// A site's own icon on a small light tile, as browsers show favicons, so dark and light marks both read.
struct SiteIcon: View {
    let image: NSImage
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = Self.look(of: image)
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        if look.fillsTile {
            // Already an app icon or a filled square: drawn as it is, with no tile of our own around it.
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            // A logo on transparency sits on a tile that follows the theme, unless its own colours would vanish
            // there: a dark mark keeps a light tile in dark mode, a white mark a dark tile in light mode.
            let lightTile = scheme == .dark ? look.darkContent : !look.lightContent
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .padding(size * 0.1)
                .frame(width: size, height: size)
                .background(shape.fill(lightTile ? Color(white: scheme == .dark ? 0.9 : 1) : Color(white: scheme == .dark ? 0.24 : 0.3)))
                .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                .clipShape(shape)
        }
    }

    struct Look { var fillsTile: Bool; var darkContent: Bool; var lightContent: Bool }

    nonisolated(unsafe) private static var looks: [ObjectIdentifier: Look] = [:]
    private static let looksLock = NSLock()

    /// How much of the icon is opaque and how bright its opaque pixels are, from a 32-pixel copy, remembered per image.
    static func look(of image: NSImage) -> Look {
        let id = ObjectIdentifier(image)
        if let known = looksLock.withLock({ looks[id] }) { return known }
        var look = Look(fillsTile: false, darkContent: false, lightContent: false)
        let n = 32
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            var opaque = 0, luminance = 0.0
            for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
                let a = Double(pixels[i + 3]) / 255
                luminance += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255 / a
                opaque += 1
            }
            let mean = opaque > 0 ? luminance / Double(opaque) : 0.5
            look = Look(fillsTile: Double(opaque) / Double(n * n) > 0.75, darkContent: mean < 0.35, lightContent: mean > 0.8)
        }
        looksLock.withLock { looks[id] = look }
        return look
    }

    /// The bundled icon for a service Latchkey knows (fetched by scripts/fetch-service-icons.py), or nil.
    static func service(_ name: String) -> NSImage? { NSImage(named: "ServiceIcons/\(name)") }
}

/// What an item is, for its icon and the line under its name: from its kind, name and service.
struct ItemType {
    let label: String
    let symbol: String
    let tint: Color

    init(_ item: SecretInfo) {
        let name = item.ref.name.uppercased()
        let looksLikeDatabase = ["DATABASE", "POSTGRES", "MYSQL", "REDIS", "MONGO", "_DSN"].contains { name.contains($0) }
        switch item.kind {
        case .key: self.init("Key File", "key.horizontal.fill", .purple)
        case .value where Self.namesAddress(name), .token where Self.namesAddress(name): self.init("URL", "globe", .teal)
        case .value: self.init("Plain Value", "tag.fill", .gray)
        case .password where looksLikeDatabase: self.init("Database", "cylinder.split.1x2.fill", .orange)
        case .password: self.init("Password", "lock.fill", .yellow)
        case .token where name.hasSuffix("API_KEY") || name.hasSuffix("_KEY"): self.init("API Key", "chevron.left.forwardslash.chevron.right", .indigo)
        case .token: self.init("Token", "key.fill", .blue)
        }
    }

    /// A name that says it holds an address: `…_URL`, `…_URI`, `…_ENDPOINT`. A password-kind value with such a name is
    /// a connection string with a password, so it stays a database or password.
    static func namesAddress(_ name: String) -> Bool {
        ["_URL", "_URI", "_ENDPOINT"].contains { name.hasSuffix($0) } || name == "URL"
    }

    private init(_ label: String, _ symbol: String, _ tint: Color) {
        self.label = label
        self.symbol = symbol
        self.tint = tint
    }
}

/// A sheet's top: its icon, title and what it's about.
struct SheetHeader: View {
    let symbol: String
    var tint: Color = .blue
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A sheet's bottom: a rule, an optional note on the left, and its buttons on the right.
struct SheetFooter<Buttons: View>: View {
    var note: String? = nil
    var noteSymbol = "lock"
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 14) {
            Divider()
            HStack(spacing: 10) {
                if let note {
                    Label(note, systemImage: noteSymbol).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                buttons()
            }
            .controlSize(.large)
        }
    }
}

/// A rounded group of rows, divided by hairlines.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

/// One line of a card: a label on the left, its content on the right, and a hairline under it unless it's the last.
struct CardRow<Content: View>: View {
    let label: String
    var last = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).foregroundStyle(.primary)
                Spacer(minLength: 12)
                content()
            }
            .padding(.vertical, 11)
            if !last { Divider() }
        }
    }
}

/// A card that leads somewhere: an icon, a title, a line of status, and a chevron.
struct LinkCard: View {
    let symbol: String
    let title: String
    let detail: String
    var dot: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    HStack(spacing: 5) {
                        if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// A sidebar row: a symbol, a title and an optional count, highlighted when it's the current view.
struct NavRow: View {
    let title: String
    let symbol: String
    /// Shown instead of the symbol when there is one: a project's or service's own icon.
    var image: NSImage? = nil
    var count: Int? = nil
    /// Show the count as a pill, for something that wants attention.
    var badge = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let image {
                    SiteIcon(image: image)
                } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                Text(title).lineLimit(1).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                if let count, badge {
                    Text("\(count)").font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.quaternary)))
                } else if let count {
                    Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small rounded label, such as a project name beside an environment badge.
struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.callout.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(.quaternary.opacity(0.7)))
    }
}

/// A labelled field inside a sheet's card.
struct FieldRow<Field: View>: View {
    let label: String
    var last = false
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label).frame(width: 120, alignment: .leading)
                field().textFieldStyle(.plain)
            }
            .padding(.vertical, 10)
            if !last { Divider() }
        }
    }
}
