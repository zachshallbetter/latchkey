import Foundation
import LatchkeyCore

// The broker without a window, for development and for Macs where the app is not installed yet.
// The app runs the same Broker; run one or the other, not both.

let env = ProcessInfo.processInfo.environment
let store = KeychainStore.automatic(accessGroup: env["LATCHKEY_ACCESS_GROUP"])
let broker = Broker(store: store, approver: SystemApprover(), allowsPush: false)

FileHandle.standardError.write(Data("""
latchkey-broker
  storage:  \(store.location)
  approval: \(broker.approver.method)
  socket:   \(Paths.socket)

""".utf8))

do {
    try broker.serve()
} catch {
    FileHandle.standardError.write(Data("latchkey-broker: \(error)\n".utf8))
    exit(1)
}
