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
| `latchkey` command-line tool: `run`, `list`, `get`, `set`, `rm`, `import`, `status` | Built |
| `latchkey-broker`: the broker without a window, for development | Built |
| App: window with sidebar, item list and detail; reveal and copy behind Touch ID; .env import sheet; activity log; menu bar panel; settings; open at login. Hosts the broker | Built; needs a team set to sync |
| Key-file delivery, expiry reminders | Not built |
| Browser extension or AutoFill provider | Not built |
| SSH agent (Secure Enclave keys) | Not built |

Tests: 20 (`swift test`; add `LATCHKEY_KEYCHAIN_TESTS=1` to include a real keychain round trip).

See [docs/apple-passwords-and-passkeys.md](docs/apple-passwords-and-passkeys.md) for how this uses iCloud Keychain
and LocalAuthentication, why items don't appear in the Passwords app, and where passkeys fit.

## Install

    scripts/install.sh

Builds both, installs `/Applications/Latchkey.app` and `~/.local/bin/latchkey`, then starts the app. Run it
again after pulling changes. The command-line tool only works while the app is running; turn on
**Open Latchkey at login** in Settings.

Without `DEVELOPMENT_TEAM` in `App/project.yml`, the app is signed ad hoc and keeps values in this Mac's login
keychain. Each reinstall changes the ad hoc signature, so macOS asks for your login password once per item the
first time the new copy reads it (choose **Always Allow**). Signing with your team fixes that and turns on iCloud
Keychain sync: see [docs/apple-passwords-and-passkeys.md](docs/apple-passwords-and-passkeys.md#setting-up-a-new-mac).

## Using the app

- **Sidebar:** All, Agent-Safe, Ask First and Activity, plus a count per kind.
- **Detail:** reveal (hides again after 30 seconds) and copy (the clipboard clears after 60 seconds) ask for
  Touch ID unless the item is agent-safe. Kind, agent-safe, note, change value and delete are there too, along
  with the item's recent activity.
- **Import:** use **File > Import .env File…** (⇧⌘I) or drop a file on the window. Review each item's kind and
  agent-safe setting, then approve once.
- **Menu bar:** search, copy a value, or jump to an item.

## Build

    swift build
    swift test

    # broker without the app (login keychain, this Mac only)
    swift run latchkey-broker

    # the app in Xcode
    cd App && xcodegen && open Latchkey.xcodeproj

Run the app or `latchkey-broker`, not both: they answer on the same socket.
Requires Xcode 16 or later on macOS 14 or later.

Debug builds can draw their own UI to a PNG without clicking:
`Latchkey --snapshot out.png [--select NAME] [--filter activity] [--import FILE] [--part sidebar|menubar]`.

## Moving a project's secrets in

`latchkey import` adds everything in a `.env` file with one approval, and `--rewrite` swaps each value in the
file for its reference:

    latchkey import .env --dry-run                 # names and what would happen; never values
    latchkey import .env --rewrite \
        --kind DATABASE_URL=password --kind API_HOST=value --agent-safe API_HOST

Items default to kind `token` and need approval to read. Items that already exist are skipped unless you pass
`--replace`. Empty values and values that are already references are left alone.

To have an agent do it, tell it something like: *Run `latchkey import .env --rewrite`. Do not open, read or
print `.env`.* The agent sees names and counts only. Values go straight from the file to the app, and you still
approve the batch with Touch ID.

## Layout

    Sources/LatchkeyCore   shared library
    Sources/latchkey       command-line tool
    Tests/LatchkeyCoreTests
    Sources/latchkey-broker  broker without a window
    scripts/               install.sh, make-icon.swift
    App/                   the macOS menu bar app (xcodegen project.yml)
    docs/

## Item kinds

| Kind | Examples | Masked in output |
|---|---|---|
| token | API keys, access tokens | yes |
| password | passwords, connection strings | yes |
| key | SSH, GPG, .p8, .pem | yes |
| value | IP addresses, host names, account ids | no |
