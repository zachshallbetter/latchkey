# Apple Passwords, iCloud Keychain and passkeys

How Latchkey uses what macOS already has, and where the platform draws lines.

## What Latchkey uses

| Need | Apple piece | Where |
|---|---|---|
| Keep values encrypted, on every Mac | **iCloud Keychain**: the data-protection keychain with `kSecAttrSynchronizable`. It's the same store, encryption and sync the Passwords app uses | `KeychainStore` (`.iCloud` mode) |
| Ask before releasing a secret or changing one | **LocalAuthentication** `.deviceOwnerAuthentication`: Touch ID, then a paired Apple Watch, then the account password. It's the same check that unlocks a passkey | `SystemApprover` |
| Know who is asking | Peer PID of the Unix socket, plus `proc_pidpath` up the parent chain | `PeerInfo` |

Kind, agent-safe, service and the files an item was imported from are stored on the keychain item itself (`kSecAttrGeneric`), and the note in `kSecAttrComment`. They sync along with the value, so a new Mac gets the same settings without extra setup. Earlier values and remote links are keychain items too.

Synced items use `kSecAttrAccessibleAfterFirstUnlock`. Synced items can't be device-only, and this class still lets a scheduled job read an agent-safe item while the screen is locked.

## What the platform does not allow

**Items don't show up in the Passwords app.** The Passwords app shows items in Apple's own access group, which third-party apps can't read or write. Latchkey's items sit in its own access group (`<TEAM>.io.latchkey.shared`) inside iCloud Keychain. They get the same end-to-end encryption, sync and account recovery. You can see them in Keychain Access as "Latchkey: ID".

**Latchkey can't read existing Passwords entries.** No API lets an app or a command-line tool pull a saved password out of the Passwords app. The only path is AutoFill into a login form. To use a token you already keep in Passwords, copy it into Latchkey once (`latchkey set ID`).

**Passkeys can't hold API tokens.** A passkey is a key pair tied to one website (its relying party). The private key never leaves the keychain, and it only signs that site's login challenges. It can't stand in for an API key or a database password. Using one from a local app also needs a real domain with an `apple-app-site-association` file. Latchkey uses the same Touch ID / Watch check through LocalAuthentication instead, which needs neither.

## Where passkey-style keys fit next

- **SSH agent (planned).** Store SSH keys in the **Secure Enclave** (CryptoKit `SecureEnclave.P256`). The key can't be exported, and each use can require Touch ID, the same model as a passkey. Secure Enclave keys never sync, so each Mac gets its own key, and you add each Mac's public key to servers once.
- **AutoFill provider (possible).** A Credential Provider extension (`ASCredentialProviderViewController`) would let Latchkey appear next to Passwords in AutoFill, for items such as web logins. Safari and the system use it, and it may take over some of the planned browser-extension work.

## Signing requirement

The data-protection keychain and iCloud sync are only available to a process signed with a team ID and a `keychain-access-groups` entitlement. So:

- **The app**, signed with your team, stores in iCloud Keychain.
- **`latchkey-broker`** (a SwiftPM build, unsigned) and an unsigned app build fall back to the login keychain on that Mac only. `latchkey status` says which store is in use.
- **The `latchkey` CLI** never touches the keychain, so it doesn't need signing.

Every Mac must run a build signed by the **same team**. The access group includes the team ID, and a different team can't see the items.

## Setting up a new Mac

See [Getting started](getting-started.md#install-from-source). In short: sign in to Xcode with the same Apple Account,
build with the same team, and run `scripts/install.sh`. Items saved before the app was signed are in the login
keychain; Settings › **Move to iCloud Keychain** moves them.

A free personal team is enough for your own Macs, though its development profiles expire after a while and need a
rebuild to renew. A paid Developer Program membership adds a Developer ID build that runs on any Mac and can be
notarized to share.
