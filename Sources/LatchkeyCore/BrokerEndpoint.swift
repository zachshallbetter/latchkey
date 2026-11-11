import Foundation

/// A path and its authentication policy travel together. An SSH environment variable must never disable
/// signature checking for an explicitly selected local endpoint.
public struct BrokerEndpoint: Equatable, Sendable {
    public enum Authentication: Equatable, Sendable {
        case sameTeamApplication(String)
        case unsignedDevelopment
        case sshForward
    }
    public let path: String
    public let authentication: Authentication

    public enum ConfigurationError: Error, LocalizedError {
        case invalidChannel, signedToolRequired, forwardingUnavailable, invalidLocalSocket
        public var errorDescription: String? {
            switch self {
            case .invalidLocalSocket: return "LATCHKEY_LOCAL_SOCKET must be an absolute path and cannot be combined with LATCHKEY_SOCKET."
            case .invalidChannel: return "LATCHKEY_BROKER must be auto, direct or app-store."
            case .signedToolRequired: return "The App Store broker requires the signed Latchkey CLI from the same developer team."
            case .forwardingUnavailable: return "SSH forwarding is not yet supported by the App Store broker. Select the direct broker explicitly."
            }
        }
    }

    public static func local(path: String, team: String?) -> Self {
        Self(path: path, authentication: team.map(Authentication.sameTeamApplication) ?? .unsignedDevelopment)
    }

    /// Terminal clients use the real user's Group Containers directory. The app obtains the matching container
    /// through FileManager's App Group API, never by assuming its sandbox home is the user's home.
    public static func appStorePath(container: URL) -> String { container.appendingPathComponent("cli.sock").path }

    public static func select(environment: [String: String], team: String?, installedAppIsStore: Bool,
                              home: URL, directPath: String) throws -> Self {
        let channel = environment["LATCHKEY_BROKER"] ?? "auto"
        guard ["auto", "direct", "app-store"].contains(channel) else { throw ConfigurationError.invalidChannel }
        let local = environment["LATCHKEY_LOCAL_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        if let local, !local.hasPrefix("/") || environment["LATCHKEY_SOCKET"].map({ !$0.isEmpty }) == true {
            throw ConfigurationError.invalidLocalSocket
        }
        let store = channel == "app-store" || (channel == "auto" && installedAppIsStore)
        if let forwarded = environment["LATCHKEY_SOCKET"], !forwarded.isEmpty {
            guard !store else { throw ConfigurationError.forwardingUnavailable }
            return Self(path: forwarded, authentication: .sshForward)
        }
        if store {
            guard let team, !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw ConfigurationError.signedToolRequired
            }
            let container = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
                .appendingPathComponent(team + "." + CodeIdentity.appIdentifier, isDirectory: true)
            return .local(path: local ?? appStorePath(container: container), team: team)
        }
        return .local(path: local ?? directPath, team: team)
    }
}
