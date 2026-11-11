# Latchkey

A secrets manager for one person's Macs and the agents running on them. "Latchkey" is a working name.

Files hold references (`latchkey://NAME`), the app holds the values, and `latchkey run` swaps them in when a
command starts. Agents get only the items marked agent-safe; everything else needs approval in the app.

## Status

| Part | State |
|---|---|
| `LatchkeyCore` library: references, `.env` parsing, output masking, wire protocol, caller identification | Built, 7 tests |
| `latchkey` command-line tool: `run`, `list`, `get`, `set`, `rm`, `status` | Built; needs the app to answer |
| App: window UI, background broker, Keychain storage (iCloud-synced) | Not built |
| Key-file delivery, expiry reminders | Not built |
| Browser extension (Chrome and Brave, then Safari) | Not built |
| SSH agent | Not built |

Nothing stores a secret yet.

## Build

    swift build
    swift test

Requires Xcode 16 or later on macOS 14 or later.

## Layout

    Sources/LatchkeyCore   shared library
    Sources/latchkey       command-line tool
    Tests/LatchkeyCoreTests
    App/                   the macOS app (empty for now)

## Item kinds

| Kind | Examples | Masked in output |
|---|---|---|
| token | API keys, access tokens | yes |
| password | passwords, connection strings | yes |
| key | SSH, GPG, .p8, .pem | yes |
| value | IP addresses, host names, account ids | no |
