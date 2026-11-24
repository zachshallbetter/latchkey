import Foundation
import LatchkeyCore
import SafariServices

/// Pistachio for Safari's native side. Safari hands it messages from the extension's background script; it passes
/// them to the Pistachio app over the socket in the shared App Group container and returns the answer. It can list
/// where items can go and which may be filled on this page (names only), save a value, and fill one item; the app
/// asks you to approve each save and each fill, and decides itself which sites an item may be filled on.
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
            return ["ok": false, "error": "This copy of Pistachio for Safari can't reach the app (it isn't signed with Pistachio's team)."]
        }
        return BrowserExtensionMessages.answer(message) { request in
            try? BrokerClient.send(request, socketPath: socket)
        }
    }
}
