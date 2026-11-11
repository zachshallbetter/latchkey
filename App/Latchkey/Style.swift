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
        case .value where name.hasSuffix("_URL") || name.hasSuffix("_URI"): self.init("URL", "globe", .teal)
        case .value: self.init("Plain Value", "tag.fill", .gray)
        case .password where looksLikeDatabase: self.init("Database", "cylinder.split.1x2.fill", .orange)
        case .password: self.init("Password", "lock.fill", .orange)
        case .token where name.hasSuffix("API_KEY") || name.hasSuffix("_KEY"): self.init("API Key", "chevron.left.forwardslash.chevron.right", .indigo)
        case .token: self.init("Token", "key.fill", .blue)
        }
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
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                Text(title).lineLimit(1).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                if let count { Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small heading over a group of sidebar rows.
struct SidebarHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 10).padding(.top, 6)
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
