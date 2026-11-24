import AppKit
import LatchkeyCore
import SwiftUI

/// Presentation only: the preference changes the running app, never the signed bundle or Finder metadata.
@MainActor
enum AppBranding {
    static func image(for choice: AppPreferences.Icon) -> NSImage {
        NSImage(named: choice == .key ? "KeyDockIcon" : NSImage.applicationIconName)
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
