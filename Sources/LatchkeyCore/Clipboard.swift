import AppKit

/// Putting values on the clipboard: this Mac only, hidden from clipboard managers that honour the convention, and
/// cleared after a minute if nothing else was copied meanwhile.
public enum Clipboard {
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let clearAfter: TimeInterval = 60

    /// Replaces the clipboard with `text`. Without `.currentHostOnly`, Universal Clipboard hands it to the owner's other
    /// devices. Returns the change count to give `clear(ifUnchangedSince:)`.
    @discardableResult
    public static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealed)
        pasteboard.setString("", forType: transient)
        return pasteboard.changeCount
    }

    /// Empties the clipboard unless something was copied since `stamp`. True if it did.
    @discardableResult
    public static func clear(ifUnchangedSince stamp: Int, on pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == stamp else { return false }
        pasteboard.clearContents()
        return true
    }
}
