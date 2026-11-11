import Darwin
import Foundation
import Security

/// Who signed a running program. The app uses it to tell its own command-line tool from any other program on its
/// socket, and the tool uses it to make sure the socket belongs to the app.
public enum CodeIdentity {
    /// The app's bundle ID and the identifier the command-line tool is signed with.
    public static let appIdentifier = "io.snackstud.latchkey"
    public static let toolIdentifier = "io.snackstud.latchkey.cli"

    /// The team that signed this process, or nil for an unsigned or ad hoc build, which can't vouch for anyone.
    public static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return team(of: code)
    }()

    /// True if the process on the other end of `fd` is signed by Apple-issued certificate for `team` with
    /// `identifier`. The kernel's audit token names the process, so a reused process ID can't stand in for it.
    public static func peer(_ fd: Int32, is identifier: String, team: String) -> Bool {
        guard let token = auditToken(fd) else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The audit token of the process on the other end of a Unix socket.
    static func auditToken(_ fd: Int32) -> Data? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let SOL_LOCAL_: Int32 = 0
        let LOCAL_PEERTOKEN_: Int32 = 0x006
        guard getsockopt(fd, SOL_LOCAL_, LOCAL_PEERTOKEN_, &token, &len) == 0 else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    static func team(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
