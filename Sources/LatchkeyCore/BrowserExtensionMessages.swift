import Foundation

/// Shared translation only; each transport authenticates its caller before invoking it.
public enum BrowserExtensionMessages {
    public static func answer(_ message: [String: Any], browserName: String = "Safari", send: (Request) -> Response?) -> [String: Any] {
        let page = message["page"] as? String

        switch message["op"] as? String {
        case "status":
            guard let r = send(Request(op: "status")), r.ok else { return unreachable() }
            return ["ok": true]

        case "places":
            // Where a new item can go, and the items it might replace: IDs only, never values.
            guard let r = send(Request(op: "list")), r.ok else { return unreachable() }
            let items = r.secrets ?? []
            let places = Array(Set(items.compactMap { i -> String? in
                let id = ItemID(i.name); return id.map { $0.isShared ? nil : "\($0.project)/\($0.environment)" } ?? nil
            })).sorted()
            let existing = items.map { ["id": $0.name, "service": $0.service ?? ""] }
            return ["ok": true, "places": places, "items": existing]

        case "save":
            guard let id = message["id"] as? String, Wire.isValidName(id),
                  let value = message["value"] as? String, !value.isEmpty, value.utf8.count <= 16 * 1024 else {
                return ["ok": false, "error": "Give the item a name such as STRIPE_SECRET_KEY or shop/production/STRIPE_SECRET_KEY."]
            }
            let kind = ItemKind(rawValue: message["kind"] as? String ?? "token") ?? .token
            // A note for new items only, so replacing a value never overwrites a note you wrote.
            let exists = send(Request(op: "list"))?.secrets?.contains { $0.name == id } ?? false
            let note = exists ? nil : page.map { "saved from \($0) by Pistachio for \(browserName)" }
            guard let r = send(Request(op: "set", names: [id], value: value, kind: kind, note: note,
                                       service: message["service"] as? String, page: page)) else { return unreachable() }
            return r.ok ? ["ok": true, "id": id] : ["ok": false, "error": r.error ?? "Not saved."]

        case "fillable":
            // Items the app would let this page have: names, services and kinds, never values. The app checks again on fill.
            guard let page, let r = send(Request(op: "list")), r.ok else { return unreachable() }
            let items = (r.secrets ?? []).filter { Services.mayFill(origin: page, item: $0) }
            return ["ok": true, "host": Services.fillHost(page) ?? "",
                    "items": items.map { ["id": $0.name, "service": $0.service ?? "", "kind": $0.kind.rawValue] }]

        case "fill":
            guard let id = message["id"] as? String, Wire.isValidName(id) else { return ["ok": false, "error": "Choose an item to fill."] }
            guard let r = send(Request(op: "fill", names: [id], page: page)) else { return unreachable() }
            guard r.ok, let value = r.values?[id] else { return ["ok": false, "error": r.error ?? (r.missing != nil ? "\(id) isn't in Pistachio." : "Not filled.")] }
            return ["ok": true, "value": value]

        default:
            return ["ok": false, "error": "Unknown request."]
        }
    }

    public static func unreachable() -> [String: Any] {
        ["ok": false, "error": "Pistachio isn't running, or this extension isn't the one that came with it. Open Pistachio and try again."]
    }
}
