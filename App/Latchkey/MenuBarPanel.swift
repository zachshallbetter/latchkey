import AppKit
import LatchkeyCore
import LocalAuthentication
import SwiftUI

/// The menu bar icon: a click opens the main window; a right-click (or Control-click) shows the panel below it.
/// SwiftUI's MenuBarExtra can't tell the two apart, so this is an AppKit status item.
@MainActor
final class MenuBarItem: NSObject {
    private static var shared: MenuBarItem?
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    /// Called once the main window's scene is up, so the item can open that window later.
    static func install(_ model: AppModel, openWindow: OpenWindowAction) {
        model.openMainWindow = { openWindow(id: "main"); NSApp.activate() }
        guard shared == nil else { return }
        shared = MenuBarItem(model: model)
    }

    static func updateIcon() { shared?.updateIcon() }

    private func updateIcon() {
        let name = AppPreferences().icon == .key ? "MenuBarIcon" : "PistachioMenuBarIcon"
        let icon = NSImage(named: name)?.copy() as? NSImage
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Pistachio"
        item.button?.image = icon
    }

    private init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel(model: model) { [weak self] in
            self?.popover.performClose(nil)
        })
        guard let button = item.button else { return }
        updateIcon()
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Latchkey: click to open, right-click for quick access"
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsPanel = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if popover.isShown { popover.performClose(nil); if wantsPanel { return } }
        if wantsPanel {
            model.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            model.openMainWindow()
        }
    }
}

struct MenuBarPanel: View {
    let model: AppModel
    var close: () -> Void = {}
    @State private var query = ""
    @State private var listHeight: CGFloat = 0

    private func open(select name: String? = nil) {
        if let name { model.filter = .all; model.selection = [name] }
        close()
        model.openMainWindow()
    }

    var body: some View {
        Group {
            if model.locked { lockedBody } else { unlockedBody }
        }
        // No keyboard focus rings, here or anywhere in the app (the scenes in LatchkeyApp set the same).
        .focusEffectDisabled()
    }

    /// While locked the panel lists nothing, and unlocks right here: Touch ID in the panel, as on the lock screen, or
    /// Use Password… for the system sheet. Unlocking shows the items in place.
    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Latchkey is locked", systemImage: "lock.fill").font(.headline)
            if let touchID {
                VStack(spacing: 4) {
                    InlineTouchID(context: touchID,
                                  start: { model.unlockWithTouchID(touchID) { if self.touchID === touchID { self.touchID = nil } } },
                                  stop: { stopTouchID() }, needsKeyWindow: false)
                    Text("Touch ID to unlock").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                Text("Unlock to see your items.").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Use Password…") { stopTouchID(); model.unlock() }.disabled(model.unlocking)
                Spacer()
                Button("Quit") { close(); AppDelegate.quitting = true; NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear(perform: startTouchID)
        .onDisappear(perform: stopTouchID)
    }

    /// The Touch ID request the panel shows while locked; nil when this Mac has none or it gave up.
    @State private var touchID: LAContext?

    private func startTouchID() {
        guard model.locked, !model.unlocking, touchID == nil else { return }
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) { touchID = context }
    }

    private func stopTouchID() {
        touchID?.invalidate()
        touchID = nil
    }

    @ViewBuilder private var unlockedBody: some View {
        let q = query.lowercased()
        let list = model.items.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.synced ? "iCloud Keychain" : "This Mac only", systemImage: model.synced ? "icloud" : "desktopcomputer")
                    .font(.headline)
                Spacer()
                Button { model.showingAdd = true; open() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New item")
            }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list) { item in
                        HStack(spacing: 8) {
                            KindIcon(kind: item.kind, size: 22)
                            Text(item.name).font(.callout.monospaced()).lineLimit(1)
                            Spacer()
                            if item.agentSafe { Image(systemName: "person.badge.shield.checkmark.fill").foregroundStyle(.green) }
                            Button { Task { await model.copyValue(item.name) } } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy value")
                        }
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { open(select: item.name) }
                    }
                    if list.isEmpty {
                        Text(model.items.isEmpty ? "No items yet." : "No matches.").foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // A ScrollView has no height of its own in a popover; size it to its rows, up to 280 points.
            .frame(height: min(max(listHeight, 30), 280))
            if let e = model.log.first {
                Divider()
                ActivityRow(entry: e).font(.caption)
            }
            Divider()
            HStack {
                Button("Open Latchkey") { open() }
                Spacer()
                Button("Lock") { close(); model.lock(byHand: true) }
                Button("Settings…") { close(); model.openSettings() }
                Button("Quit") { close(); AppDelegate.quitting = true; NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }
}
