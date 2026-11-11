# Development

## Layout

```
Package.swift              LatchkeyCore (library), latchkey (CLI), latchkey-broker (broker without a window), tests
Sources/LatchkeyCore/      everything both the CLI and the app use
Sources/latchkey/          the command-line tool
Sources/latchkey-broker/   the broker without a window, for development
Tests/LatchkeyCoreTests/   unit tests
App/project.yml            the app's XcodeGen project (the .xcodeproj is generated, not committed)
App/Latchkey/              the SwiftUI app
App/Branding/logo.svg      the logo source: a key with a tag
scripts/install.sh         build and install the app and CLI (development)
scripts/release.sh         Developer ID build, notarized, in a disk image (see docs/releasing.md)
docs/                      user and developer documentation
site/                      the product website and developer docs, static HTML (see docs/site.md)
```

## Building and testing

```bash
swift build
swift test                                  # unit tests
LATCHKEY_KEYCHAIN_TESTS=1 swift test        # also round-trips through your real login keychain
cd App && xcodegen && open Latchkey.xcodeproj
scripts/install.sh                          # build Release, install the app and CLI, restart the app
```

The CLI needs macOS 14 or later; the app needs macOS 15 or later. `scripts/install.sh` signs with
`DEVELOPMENT_TEAM` from `App/project.yml`, or ad hoc (without the keychain entitlement) when it's empty. If a shared
build register exists at `~/Projects/_worktrees/.register/reg`, the script runs its builds through it.

`swift run latchkey-broker` answers the CLI without the app (login keychain, this Mac only). Run it or the app, not
both: they use the same socket. It refuses pushes.

## How it fits together

```
latchkey (CLI) ──JSON over a Unix socket──► Broker (in the app) ──► SecretStore ──► keychain
                                              │                    VersionStore     (latchkey, latchkey.history,
                                              ├─ Approver           RemoteStore      latchkey.remote services)
                                              ├─ GrantStore ──► keychain (latchkey.grants, this Mac)
                                              ├─ access log ──► access.jsonl
                                              └─ RemoteRunner ──► vercel / gh / railway / flyctl
```

- **`Broker`** handles every request: one at a time, so approval panels never stack. It decides what's released,
  asks for approval, writes the log, and keeps versions.
- **`KeychainStore`** keeps items as generic passwords (service `latchkey`, account = item ID). Kind, agent-safe,
  service and "used in" are JSON in `kSecAttrGeneric`; the note is `kSecAttrComment`. `.iCloud` mode uses the
  data-protection keychain with `kSecAttrSynchronizable` in the app's access group; `.thisMac` uses the login
  keychain. `KeychainStore.automatic` picks by trying a write (reads from an unentitled process just say "not
  found").
- **`SystemApprover`** uses LocalAuthentication; the app's `PanelApprover` shows the approval panel first.
- **`PeerInfo`** reads the caller's PID, working folder and command line from the kernel and walks parent processes.
  **`CodeIdentity`** checks code signatures through the socket's audit token: the app recognizes its own tool
  (`io.snackstud.latchkey.cli`), and the tool refuses to talk to anything but the app (`io.snackstud.latchkey`), both
  signed by the same team. `latchkey status` shows what each side saw. Requests carry no folder or command of their
  own; the broker never trusts what a request says about its caller.
- **`EnvFile`**, **`References`**, **`EnvImport`** parse, resolve, rewrite and plan imports.
- **`Masker`** replaces values in streamed output, holding back a partial match across chunk boundaries.
- **`Repo`** finds a folder's repository by reading git's files (worktrees share a common `.git`).

## The wire protocol

One JSON line from the CLI, one JSON line back (`Request` and `Response` in `Wire.swift`; ISO 8601 dates, sorted
keys). `op` is one of:

| op | |
|---|---|
| `status`, `list` | Status and item list (never values) |
| `check` | What `get` would do for names, without asking or releasing anything |
| `get` | Values for names, after approval, grants or agent-safe |
| `set`, `update`, `rm`, `move`, `import` | Changes; each asks once |
| `history`, `deleted`, `version`, `restore`, `forget` | Version history |
| `grants`, `grant`, `revoke` | Grants |
| `links`, `link`, `unlink`, `remote-status`, `push` | Remote locations |

New fields are optional so older CLIs keep working. Unknown `op` values are refused. `origin: "mcp"` marks requests
from `latchkey mcp`: approval panels say an agent asked, and grants it asks for are limited (`Broker.grant`).

The CLI target holds `main.swift` (commands), `Run.swift` (filling in an environment and masking output, shared by
`run`, `check` and the MCP server) and `MCP.swift` (`latchkey mcp`: JSON-RPC over standard input and output).

## Adding a remote service

Add a case to `RemoteTarget.Service`, then fill in `label`, `tool`, `problem` (required fields), `isProduction`,
`pushCommands` (values on standard input only), `listCommand` and `names(fromListOutput:)` (keep names, drop values).
Add tests in `RemoteTests.swift` with `FakeRunner`; no test should run a real tool.

## Checking the UI without clicking

Debug builds can draw their own UI to a PNG:

```bash
build/DerivedData/Build/Products/Debug/Latchkey.app/Contents/MacOS/Latchkey \
  --snapshot out.png [--sample] [--select ID,...] [--filter all|activity|grants|project:NAME] \
  [--part sidebar|menubar|approval|list|bulk|move|detail|deleted|remote|pushapproval] -ApplePersistenceIgnoreState YES
```

`--sample` uses example data and never loads your items, so nothing real is shown. `--part` draws one view off screen (more reliable than the
whole window when started from a shell).

## The logo and icon

`App/Branding/logo.svg` is the source, a key with a tag. The app icon is `App/Latchkey/AppIcon.icon`, an Icon Composer
document with light and dark appearances that colours the mark itself; edit it in Icon Composer (in Xcode's
Applications folder). The menu bar icon and in-app mark are template copies of the SVG in `Assets.xcassets`
(`MenuBarIcon`, `Logo`), and the website uses `site/logo.svg`.

## Conventions

- Values never appear in logs, errors, test output or CLI output (except `latchkey get`).
- Every change to items goes through the broker, so it's approved and logged.
- Tests use `MemoryStore`, `MemoryVersionStore`, `MemoryRemoteStore`, `FixedApprover` and `FakeRunner`; nothing
  touches the real keychain unless `LATCHKEY_KEYCHAIN_TESTS=1`.
