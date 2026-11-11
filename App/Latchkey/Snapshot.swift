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
        if CommandLine.arguments.contains("--sample") {
            model.items = sampleItems
            model.log = []
            model.grants = []
            model.deleted = sampleVersions.filter { $0.reason == .deleted }
            model.links = [
                RemoteLink(id: "a1b2c3", scope: "shop/production", target: RemoteTarget(service: .vercel, project: "shop", environment: "production"),
                           pushed: ["shop/production/DATABASE_URL": Date().addingTimeInterval(-86400)]),
                RemoteLink(id: "d4e5f6", scope: "shop/production", target: RemoteTarget(service: .github, environment: "production", repo: "me/shop")),
            ]
        }
        if let names = arg("--select") {
            model.selection = Set(names.split(separator: ",").map(String.init))
            model.reveal(Array(model.selection))
        }
        if arg("--filter") == "activity" { model.filter = .activity }
        if arg("--filter") == "grants" { model.filter = .grants }
        if let f = arg("--filter"), f.hasPrefix("project:") { model.filter = .project(String(f.dropFirst(8))) }
        if arg("--part") == "approval" {
            var sample = ApprovalRequest(action: .read, names: ["DATABASE_URL", "STRIPE_KEY"], chain: ["zsh", "claude", "Terminal"],
                                         folder: NSHomeDirectory() + "/Projects/site", command: "npm test -- --watch=false",
                                         reason: "release DATABASE_URL and STRIPE_KEY")
            sample.sessionName = "claude"
            sample.offersGrant = true
            drawOffscreen(ApprovalView(request: sample) { _ in }, to: path)
            return
        }
        if let f = arg("--import") { model.beginImport(URL(fileURLWithPath: f)) }
        if arg("--part") == "sidebar" {
            drawOffscreen(Sidebar(model: model).frame(width: 260, height: 640), to: path)
            return
        }
        if let q = arg("--search") { model.search = q }
        if arg("--part") == "detail", let item = model.selectedItem {
            drawOffscreen(ItemDetail(model: model, item: item).frame(width: 540, height: 1180), to: path)
            return
        }
        if arg("--part") == "deleted" {
            drawOffscreen(DeletedList(model: model).frame(width: 440, height: 260), to: path)
            return
        }
        if arg("--part") == "remote" {
            drawOffscreen(RemoteSheet(model: model, scope: arg("--scope") ?? "shop/production"), to: path)
            return
        }
        if arg("--part") == "additem" {
            drawOffscreen(AddItemSheet(model: model), to: path)
            return
        }
        if arg("--part") == "changevalue", let item = model.selectedItem {
            drawOffscreen(ChangeValueSheet(model: model, item: item), to: path)
            return
        }
        if arg("--part") == "edititem", let item = model.selectedItem {
            drawOffscreen(EditItemSheet(model: model, item: item), to: path)
            return
        }
        if arg("--part") == "overview" {
            drawOffscreen(OverviewView(model: model).frame(width: 420, height: 760), to: path)
            return
        }
        if arg("--part") == "pushapproval" {
            var r = ApprovalRequest(action: .push, names: ["shop/production/DATABASE_URL", "shop/production/STRIPE_SECRET_KEY"],
                                    chain: ["the Latchkey app"], folder: "", reason: "push 2 items")
            r.targets = ["Vercel shop · production", "GitHub Actions me/shop · environment production"]
            r.production = true
            drawOffscreen(ApprovalView(request: r) { _ in }, to: path)
            return
        }
        if arg("--part") == "list" {
            drawOffscreen(ItemList(model: model).frame(width: 400, height: 620), to: path)
            return
        }
        if arg("--part") == "bulk" {
            drawOffscreen(BulkPanel(model: model, ids: model.selection.sorted()).frame(width: 520, height: 560), to: path)
            return
        }
        if arg("--part") == "move" {
            drawOffscreen(MoveSheet(model: model, preselected: model.selection.sorted()), to: path)
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
        let shopDev = [NSHomeDirectory() + "/Projects/shop/.env.local"]
        return [
            i("shop/development/DATABASE_URL", .password, "Neon", used: shopDev),
            i("shop/development/PGHOST", .value, "Neon", safe: true, used: shopDev),
            i("shop/development/API_TOKEN", .token, nil, used: shopDev),
            i("shop/production/DATABASE_URL", .password, "Neon"),
            i("shop/production/STRIPE_SECRET_KEY", .token, "Stripe"),
            i("shop/preview/DATABASE_URL", .password, "Neon"),
            i("site/production/RESEND_API_KEY", .token, "Resend"),
            i("site/development/NEXT_PUBLIC_API_HOST", .value, nil, safe: true),
            i("GEMINI_API_KEY", .token, "Google"),
            i("GITHUB_TOKEN", .token, "GitHub"),
        ]
    }

    static var usesSample: Bool { requested && CommandLine.arguments.contains("--sample") }

    /// Example history for screenshots.
    static var sampleVersions: [Version] {
        let now = Date()
        func v(_ item: String, _ ago: Double, _ reason: Version.Reason, _ by: String) -> Version {
            Version(id: "\(item)#\(Int(ago))", item: item, savedAt: now.addingTimeInterval(-ago), reason: reason, by: by,
                    kind: .password, agentSafe: false, note: "", service: "Neon", usedIn: nil)
        }
        return [
            v("shop/production/DATABASE_URL", 3 * 3600, .changed, "the Latchkey app"),
            v("shop/production/DATABASE_URL", 9 * 86400, .changed, "zsh › claude"),
            v("shop/production/DATABASE_URL", 40 * 86400, .restored, "the Latchkey app"),
            v("old-site/production/SENTRY_DSN", 2 * 86400, .deleted, "the Latchkey app"),
        ]
    }

    /// For views the window snapshot cannot capture (the floating glass sidebar, the menu bar panel).
    static func drawOffscreen<V: View>(_ view: V, to path: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
