# Latchkey

A secrets manager for one person's Macs and the agents running on them. "Latchkey" is a working name.

Files hold references (`latchkey://NAME`), the app holds the values, and `latchkey run` swaps them in when a
command starts. Agents get only the items marked agent-safe; everything else needs approval in the app.

## Status

| Part | State |
|---|---|
| `LatchkeyCore` library: references, `.env` parsing, output masking, wire protocol, caller identification | Built |
| Keychain storage: iCloud Keychain when signed, login keychain otherwise | Built |
| Broker: agent-safe policy, approval panel then Touch ID / Apple Watch / password, grants, access log | Built |
| `latchkey` command-line tool: `run`, `list`, `get`, `set`, `rm`, `import`, `grant`, `grants`, `revoke`, `status`; starts the app if needed | Built |
| `latchkey-broker`: the broker without a window, for development | Built |
| App: window with sidebar, item list and detail; reveal and copy behind Touch ID; .env import sheet; activity log; menu bar panel; settings; open at login. Hosts the broker | Built; needs a team set to sync |
| Key-file delivery, expiry reminders | Not built |
| Browser extension or AutoFill provider | Not built |
| SSH agent (Secure Enclave keys) | Not built |

Tests: 28 (`swift test`; add `LATCHKEY_KEYCHAIN_TESTS=1` to include a real keychain round trip).

See [docs/apple-passwords-and-passkeys.md](docs/apple-passwords-and-passkeys.md) for how this uses iCloud Keychain
and LocalAuthentication, why items don't appear in the Passwords app, and where passkeys fit.

## Install

    scripts/install.sh

Builds both, installs `/Applications/Latchkey.app` and `~/.local/bin/latchkey`, then starts the app. Run it
again after pulling changes. The command-line tool starts the app if it isn't running (set
`LATCHKEY_NO_LAUNCH=1` to turn that off); **Open Latchkey at login** in Settings avoids the wait.

Without `DEVELOPMENT_TEAM` in `App/project.yml`, the app is signed ad hoc and keeps values in this Mac's login
keychain. Each reinstall changes the ad hoc signature, so macOS asks for your login password once per item the
first time the new copy reads it (choose **Always Allow**). Signing with your team fixes that and turns on iCloud
Keychain sync: see [docs/apple-passwords-and-passkeys.md](docs/apple-passwords-and-passkeys.md#setting-up-a-new-mac).

## Approvals and grants

Reading an item that isn't agent-safe from a command shows Latchkey's approval panel: the items, the program
asking (for example `zsh › claude`), its folder and its command. Choose **Deny**, **Allow Once**, or **Allow from
this folder for** 1 hour to 7 days. Touch ID, Apple Watch or your password then confirms the choice. Requests you
make in the Latchkey window go straight to Touch ID. An unanswered panel counts as a denial after 90 seconds.

A **grant** lets commands run from one folder, and the folders inside it, read some items without asking until
it ends. Make one from the approval panel, from **Grants** in the window, or ahead of time before you leave an
agent working:

    latchkey grant DATABASE_URL,STRIPE_KEY --folder ~/Projects/site --for 2h
    latchkey grants
    latchkey revoke 3f9a1c        # or: latchkey revoke all

Grants are kept on this Mac only (`~/Library/Application Support/Latchkey/grants.json`), last at most 7 days,
and show up in Activity when they're made, used and revoked.

## Using the app

- **Sidebar:** All, Agent-Safe, Ask First and Activity, plus a count per kind.
- **Detail:** reveal (hides again after 30 seconds) and copy (the clipboard clears after 60 seconds) ask for
  Touch ID unless the item is agent-safe. Kind, agent-safe, note, change value and delete are there too, along
  with the item's recent activity.
- **Import:** use **File > Import .env File…** (⇧⌘I) or drop a file on the window. Review each item's kind and
  agent-safe setting, then approve once.
- **Grants:** what each grant covers and when it ends; revoke one or all, or make a new one.
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
`Latchkey --snapshot out.png [--select NAME] [--filter activity|grants] [--import FILE] [--part sidebar|menubar|approval] -ApplePersistenceIgnoreState YES`
(the last flag makes a copy started from a shell bring up its window).

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
    App/Branding/          the logo (key.svg)
    scripts/               install.sh
    App/                   the macOS menu bar app (xcodegen project.yml)
    docs/

## Item kinds

| Kind | Examples | Masked in output |
|---|---|---|
| token | API keys, access tokens | yes |
| password | passwords, connection strings | yes |
| key | SSH, GPG, .p8, .pem | yes |
| value | IP addresses, host names, account ids | no |

## Logo

The key is a Font Awesome Pro glyph (commercial license; the notice is kept inside each copy of the SVG). The source
is `App/Branding/key.svg`.

The app icon is `App/Latchkey/AppIcon.icon`, an Icon Composer document with a light and a dark appearance (macOS
draws the tinted and clear versions from them). Open it in Icon Composer (in Xcode's Applications folder) to change
colours or glass. The menu bar icon and the in-app mark are copies of the SVG in `Assets.xcassets` (`MenuBarIcon`,
`Logo`) and follow the system's light and dark themes on their own.
