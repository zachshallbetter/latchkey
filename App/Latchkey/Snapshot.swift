#if DEBUG
import AppKit
import LatchkeyCore
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

    private static var started = false

    /// Off-screen parts don't need the window, so they start from launch rather than wait for it to appear.
    static func startParts(_ model: AppModel) {
        guard arg("--part") != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { runIfRequested(model) }
    }

    /// Call once the window is on screen (or from `startParts`). Runs once.
    static func runIfRequested(_ model: AppModel) {
        guard let path = arg("--snapshot"), !started else { return }
        started = true
        if CommandLine.arguments.contains("--sample") { model.items = sampleItems }
        if let name = arg("--select") { model.selection = name }
        if arg("--filter") == "activity" { model.filter = .activity }
        if arg("--filter") == "grants" { model.filter = .grants }
        if let f = arg("--filter"), f.hasPrefix("project:") { model.filter = .project(String(f.dropFirst(8))) }
        if arg("--part") == "approval" {
            let sample = ApprovalRequest(action: .read, names: ["DATABASE_URL", "STRIPE_KEY"], chain: ["zsh", "claude", "Terminal"],
                                         folder: NSHomeDirectory() + "/Projects/site", command: "npm test -- --watch=false",
                                         reason: "release DATABASE_URL, STRIPE_KEY")
            drawOffscreen(ApprovalView(request: sample) { _ in }, to: path)
            return
        }
        if let f = arg("--import") { model.beginImport(URL(fileURLWithPath: f)) }
        if arg("--part") == "sidebar" {
            drawOffscreen(Sidebar(model: model).frame(width: 260, height: 640), to: path)
            return
        }
        if arg("--part") == "move" {
            drawOffscreen(MoveSheet(model: model, preselected: model.selection.map { [$0] } ?? []), to: path)
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

    /// Example projects for screenshots: nothing here is a real value or a real project.
    static var sampleItems: [SecretInfo] {
        let now = Date()
        func i(_ id: String, _ kind: ItemKind, _ service: String?, safe: Bool = false, used: [String]? = nil) -> SecretInfo {
            SecretInfo(name: id, kind: kind, agentSafe: safe, note: used == nil ? "" : "imported from .env.local",
                       updatedAt: now, usedIn: used, service: service)
        }
        let acpDev = [NSHomeDirectory() + "/Projects/acp/.env.local"]
        return [
            i("acp/development/DATABASE_URL", .password, "Neon", used: acpDev),
            i("acp/development/PGHOST", .value, "Neon", safe: true, used: acpDev),
            i("acp/development/ACP_GATEWAY_TOKEN", .token, nil, used: acpDev),
            i("acp/production/DATABASE_URL", .password, "Neon"),
            i("acp/production/STRIPE_SECRET_KEY", .token, "Stripe"),
            i("acp/preview/DATABASE_URL", .password, "Neon"),
            i("site/production/RESEND_API_KEY", .token, "Resend"),
            i("site/development/NEXT_PUBLIC_API_HOST", .value, nil, safe: true),
            i("GEMINI_API_KEY", .token, "Google"),
            i("GITHUB_TOKEN", .token, "GitHub"),
        ]
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
