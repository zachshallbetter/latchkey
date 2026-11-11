#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only. `Latchkey --snapshot out.png [--select NAME] [--filter activity]` opens the main window,
/// draws it to a PNG and exits, without starting the broker. For doc screenshots and checking the UI without
/// clicking or screen-recording permission (an app may always draw its own windows).
@MainActor
enum Snapshot {
    static func arg(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static var requested: Bool { arg("--snapshot") != nil }

    /// Call once the window is on screen.
    static func runIfRequested(_ model: AppModel) {
        guard let path = arg("--snapshot") else { return }
        if let name = arg("--select") { model.selection = name }
        if arg("--filter") == "activity" { model.filter = .activity }
        if let f = arg("--import") { model.beginImport(URL(fileURLWithPath: f)) }
        if arg("--part") == "sidebar" {
            drawOffscreen(Sidebar(model: model).frame(width: 260, height: 640), to: path)
            return
        }
        if arg("--part") == "menubar" {
            drawOffscreen(MenuBarPanel(model: model), to: path)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let target = NSApp.windows.first { $0.attachedSheet != nil } ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 500 }
            let window = target?.attachedSheet ?? target
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }

    /// For views the window snapshot cannot capture (the floating glass sidebar, the menu bar panel).
    static func drawOffscreen<V: View>(_ view: V, to path: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
