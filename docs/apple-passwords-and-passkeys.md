# Apple Passwords, iCloud Keychain and passkeys

How Latchkey uses what macOS already has, and where the platform draws lines.

## What Latchkey uses

| Need | Apple piece | Where |
|---|---|---|
| Keep values encrypted, on every Mac | **iCloud Keychain**: the data-protection keychain with `kSecAttrSynchronizable`. It's the same store, encryption and sync the Passwords app uses | `KeychainStore` (`.iCloud` mode) |
| Ask before releasing a secret or changing one | **LocalAuthentication** `.deviceOwnerAuthentication`: Touch ID, then a paired Apple Watch, then the account password. It's the same check that unlocks a passkey | `SystemApprover` |
| Know who is asking | Peer PID of the Unix socket, plus `proc_pidpath` up the parent chain | `PeerInfo` |

Kind and agent-safe are stored on the keychain item itself (`kSecAttrGeneric`), and the note is stored in `kSecAttrComment`. They sync along with the value, so a new Mac gets the same policy without extra setup.

Synced items use `kSecAttrAccessibleAfterFirstUnlock`. Synced items can't be device-only, and this class still lets a scheduled job read an agent-safe item while the screen is locked.

## What the platform does not allow

**Items don't show up in the Passwords app.** The Passwords app shows items in Apple's own access group, which third-party apps can't read or write. Latchkey's items sit in its own access group (`<TEAM>.io.latchkey.shared`) inside iCloud Keychain. They get the same end-to-end encryption, sync and account recovery. You can see them in Keychain Access as "Latchkey: NAME".

**Latchkey can't read existing Passwords entries.** No API lets an app or a command-line tool pull a saved password out of the Passwords app. The only path is AutoFill into a login form. To use a token you already keep in Passwords, copy it into Latchkey once (`latchkey set NAME`).

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

1. In Xcode, go to Settings > Accounts and sign in with your Apple Account.
2. Open `App/Latchkey.xcodeproj`, select the Latchkey target, go to Signing & Capabilities, and choose your team.
   This makes Xcode create your Apple Development certificate. Copy the team ID it shows into `DEVELOPMENT_TEAM`
   in `App/project.yml` (the project file is regenerated from it).
3. Run `scripts/install.sh`. It signs with your team and installs. The window's sidebar and Settings say
   "iCloud Keychain" once it worked.
4. Make sure iCloud Keychain is on: System Settings > [your name] > iCloud > Passwords & Keychain.
5. If the unsigned copy saved items, open Settings and choose **Move to iCloud Keychain**. macOS may ask for your
   login password once per item while they move.
6. On each other Mac, sign in to Xcode with the same Apple Account and run `scripts/install.sh`. A development
   profile only covers Macs registered to it, and building on a Mac registers it.

A free personal team is enough for your own Macs, though its development profiles expire after a while and
need a rebuild to renew. A paid Developer Program membership adds a Developer ID build that runs on any Mac and
can be notarized to share.
