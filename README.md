# Latchkey

A secrets manager for one person's Macs and the agents running on them. "Latchkey" is a working name.

Files hold references (`latchkey://NAME`), the app holds the values, and `latchkey run` swaps them in when a
command starts. Agents get only the items marked agent-safe; everything else needs approval in the app.

## Status

| Part | State |
|---|---|
| `LatchkeyCore` library: references, `.env` parsing, output masking, wire protocol, caller identification | Built |
| Keychain storage: iCloud Keychain when signed, login keychain otherwise | Built |
| Broker: agent-safe policy, approval by Touch ID / Apple Watch / password, access log | Built |
| `latchkey` command-line tool: `run`, `list`, `get`, `set`, `rm`, `status` | Built |
| `latchkey-broker`: the broker without a window, for development | Built |
| App: menu bar item list, add / delete / agent-safe toggle, recent access, hosts the broker | Built; needs a team set to sync |
| Key-file delivery, expiry reminders | Not built |
| Browser extension or AutoFill provider | Not built |
| SSH agent (Secure Enclave keys) | Not built |

Tests: 13 (`swift test`; add `LATCHKEY_KEYCHAIN_TESTS=1` to include a real keychain round trip).

See [docs/apple-passwords-and-passkeys.md](docs/apple-passwords-and-passkeys.md) for how this uses iCloud Keychain
and LocalAuthentication, why items don't appear in the Passwords app, and where passkeys fit.

## Build

    swift build
    swift test

    # broker without the app (login keychain, this Mac only)
    swift run latchkey-broker

    # the app (iCloud Keychain once DEVELOPMENT_TEAM is set in App/project.yml)
    cd App && xcodegen && open Latchkey.xcodeproj

Run the app or `latchkey-broker`, not both: they answer on the same socket.
Requires Xcode 16 or later on macOS 14 or later.

## Layout

    Sources/LatchkeyCore   shared library
    Sources/latchkey       command-line tool
    Tests/LatchkeyCoreTests
    Sources/latchkey-broker  broker without a window
    App/                   the macOS menu bar app (xcodegen project.yml)
    docs/

## Item kinds

| Kind | Examples | Masked in output |
|---|---|---|
| token | API keys, access tokens | yes |
| password | passwords, connection strings | yes |
| key | SSH, GPG, .p8, .pem | yes |
| value | IP addresses, host names, account ids | no |
