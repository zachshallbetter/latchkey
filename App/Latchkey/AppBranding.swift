import AppKit
import LatchkeyCore
import SwiftUI

/// Presentation only: the preference changes the running app, never the signed bundle or Finder metadata.
@MainActor
enum AppBranding {
    static func image(for choice: AppPreferences.Icon) -> NSImage {
        // Both previews follow light and dark the same way; the running app's icon can come back in another
        // appearance (a dark tile in light mode).
        NSImage(named: choice == .key ? "KeyDockIcon" : "PistachioDockIcon")
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage(size: NSSize(width: 1024, height: 1024))
    }

    static func apply() {
        // Let macOS render the bundled Icon Composer asset, including its current appearance.
        // A flattened runtime image bypasses that treatment. nil restores the original icon.
        NSApp.applicationIconImage = AppPreferences().icon == .key ? image(for: .key) : nil
        MenuBarItem.updateIcon()
    }
}

struct BrandAppIcon: View {
    var size: CGFloat
    @AppStorage(AppPreferences.Key.icon) private var icon = AppPreferences.Icon.pistachio.rawValue

    var body: some View {
        Image(nsImage: AppBranding.image(for: AppPreferences.Icon(preference: icon)))
            .resizable().scaledToFit().frame(width: size, height: size)
    }
}

/// The chosen palette's colours. The accent is brighter in dark mode and deeper in light mode so text in it stays
/// readable; the fill (prominent buttons, swatches) is dark enough for white text in both.
enum AppPalette {
    static func accent(_ palette: AppPreferences.Palette) -> Color {
        switch palette {
        case .pistachio: dynamic(dark: (0.69, 0.75, 0.36), light: (0.36, 0.44, 0.15))
        case .blue: dynamic(dark: (0.42, 0.64, 1.0), light: (0.10, 0.40, 0.85))
        case .plum: dynamic(dark: (0.82, 0.56, 0.80), light: (0.50, 0.20, 0.46))
        case .graphite: dynamic(dark: (0.74, 0.75, 0.78), light: (0.33, 0.34, 0.37))
        }
    }

    /// The app's tint: deep enough behind white text (a selected sidebar row) and bright enough as a symbol on the
    /// window background, in both appearances.
    static func tint(_ palette: AppPreferences.Palette) -> Color {
        switch palette {
        case .pistachio: dynamic(dark: (0.45, 0.56, 0.18), light: (0.36, 0.44, 0.15))
        case .blue: dynamic(dark: (0.16, 0.47, 0.96), light: (0.10, 0.40, 0.85))
        case .plum: dynamic(dark: (0.62, 0.30, 0.58), light: (0.50, 0.20, 0.46))
        case .graphite: dynamic(dark: (0.45, 0.46, 0.50), light: (0.33, 0.34, 0.37))
        }
    }

    static func fill(_ palette: AppPreferences.Palette) -> Color {
        let c: (CGFloat, CGFloat, CGFloat) = switch palette {
        case .pistachio: (0.33, 0.42, 0.13)
        case .blue: (0.10, 0.38, 0.80)
        case .plum: (0.47, 0.20, 0.44)
        case .graphite: (0.30, 0.31, 0.34)
        }
        return Color(nsColor: NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
    }

    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Tints a window's controls and selections with the chosen palette, following the preference as it changes.
private struct PaletteTint: ViewModifier {
    @AppStorage(AppPreferences.Key.palette) private var palette = ""
    @AppStorage(AppPreferences.Key.icon) private var icon = AppPreferences.Icon.pistachio.rawValue
    func body(content: Content) -> some View {
        content.tint(AppPalette.tint(AppPreferences.Palette(preference: palette, iconPreference: icon)))
    }
}

extension View {
    func paletteTint() -> some View { modifier(PaletteTint()) }
}
