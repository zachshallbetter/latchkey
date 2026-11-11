import Foundation
import LatchkeyCore
import SafariServices

/// Latchkey for Safari's native side. Safari hands it messages from the extension's background script; it passes
/// them to the Latchkey app over the socket in the shared App Group container and returns the answer. It can do two
/// things: list where items can go (names only), and save a value, which the app asks you to approve.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        // Saving waits for your approval, so answer from a background queue.
        DispatchQueue.global().async {
            let reply = NSExtensionItem()
            reply.userInfo = [SFExtensionMessageKey: Self.answer(message)]
            context.completeRequest(returningItems: [reply])
        }
    }

    static func answer(_ message: [String: Any]) -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LatchkeyAppGroup") as? String,
              let socket = Paths.extensionSocket(group: group) else {
            return ["ok": false, "error": "This copy of Latchkey for Safari can't reach the app (it isn't signed with Latchkey's team)."]
        }
        func send(_ request: Request) -> Response? { try? BrokerClient.send(request, socketPath: socket) }
        let page = message["page"] as? String

        switch message["op"] as? String {
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
            let note = exists ? nil : page.map { "saved from \($0) by Latchkey for Safari" }
            guard let r = send(Request(op: "set", names: [id], value: value, kind: kind, note: note,
                                       service: message["service"] as? String, page: page)) else { return unreachable() }
            return r.ok ? ["ok": true, "id": id] : ["ok": false, "error": r.error ?? "Not saved."]

        default:
            return ["ok": false, "error": "Unknown request."]
        }
    }

    static func unreachable() -> [String: Any] {
        ["ok": false, "error": "Latchkey isn't running, or this extension isn't the one that came with it. Open Latchkey and try again."]
    }
}
