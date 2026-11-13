import Foundation

/// The operations that need Latchkey Pro, each with the feature it is named by. Empty today: everything shipped so far
/// stays free. Add an op here when a new Pro feature is built; `Broker.handle` is the only place that enforces it.
/// Core ops (storing, reading, approving, granting, running, importing, exporting, deleting, history and restore)
/// never belong here; ProGateTests checks that against `Broker.Gate.commandLineTool`.
public enum ProGate {
    public static let features: [String: String] = [:]

    public static let ops = Set(features.keys)

    /// Prefix of every refusal, so the app can recognize one and offer the upgrade.
    static let refusalPrefix = "Latchkey Pro is needed for "

    public static func refusal(feature: String) -> String {
        "\(refusalPrefix)\(feature). Latchkey Pro is a one-time purchase in the Mac App Store version of Latchkey."
    }

    public static func isRefusal(_ error: String?) -> Bool { error?.hasPrefix(refusalPrefix) == true }
}
