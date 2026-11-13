import AppKit
import LatchkeyCore
import SwiftUI

struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private func open(select name: String? = nil) {
        if let name { model.filter = .all; model.selection = [name] }
        openWindow(id: "main")
        NSApp.activate()
    }

    var body: some View {
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
            }
            .frame(maxHeight: 280)
            if let e = model.log.first {
                Divider()
                ActivityRow(entry: e).font(.caption)
            }
            Divider()
            HStack {
                Button("Open Latchkey") { open() }
                Spacer()
                Button("Settings…") { model.openSettings(); open() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }
}
