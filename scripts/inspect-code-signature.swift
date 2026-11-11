import Foundation
import Security

// Developer tooling only. Security.framework decodes the actual signed entitlement dictionary, including DER
// signatures; codesign's human-readable or legacy XML output is not used as a machine-readable schema.
guard CommandLine.arguments.count == 2 else { exit(64) }
var code: SecStaticCode?
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { exit(1) }
var information: CFDictionary?
guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let values = information as? [String: Any] else { exit(1) }
var names: [String] = []
for certificate in values[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? [] {
    var commonName: CFString?
    if SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess, let commonName { names.append(commonName as String) }
}
let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
let output: [String: Any] = [
    "valid": SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess,
    "identifier": values[kSecCodeInfoIdentifier as String] as? String ?? "",
    "teamIdentifier": values[kSecCodeInfoTeamIdentifier as String] as? String ?? "",
    "entitlements": values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:],
    "certificateCommonNames": names,
]
guard JSONSerialization.isValidJSONObject(output),
      let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { exit(1) }
FileHandle.standardOutput.write(data + Data("\n".utf8))
