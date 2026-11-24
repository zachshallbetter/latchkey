# Development

## Layout

```
Package.swift              LatchkeyCore (library), pistachio (CLI), latchkey-broker (broker without a window), tests
Sources/LatchkeyCore/      everything both the CLI and the app use
Sources/latchkey/          the command-line tool
Sources/latchkey-broker/   the broker without a window, for development
Tests/LatchkeyCoreTests/   unit tests
App/project.yml            the app's XcodeGen project (the .xcodeproj is generated, not committed)
App/Latchkey/              the SwiftUI app
App/Safari/                Pistachio for Safari: the native handler and the extension's manifest and scripts
App/Branding/logo.svg      the logo source: a key on a ring
scripts/install.sh         build and install the app and CLI (development)
scripts/release.sh         Developer ID build, notarized, in a disk image (see docs/releasing.md)
docs/                      user and developer documentation
site/                      the product website and developer docs, static HTML (see docs/site.md)
AGENTS.md, .agents/         agent operating contract, project intent and records (Formal Project Bootstrap)
```

## Building and testing

```bash
swift build
swift test                                  # unit tests
node App/Safari/detector.test.js            # the Safari extension's key detector
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
pistachio (CLI) ──JSON over a Unix socket──► Broker (in the app) ──► SecretStore ──► keychain
                                              │                    VersionStore     (items, history,
                                              ├─ Approver           RemoteStore      remote services)
                                              ├─ GrantStore ──► keychain (grants, this Mac)
                                              ├─ access log ──► access.jsonl (HMAC chain; key and head in the keychain)
                                              └─ RemoteRunner ──► vercel / gh / railway / flyctl
```

- **`Broker`** handles every request: one at a time, so approval panels never stack. It decides what's released,
  asks for approval, writes the log, and keeps versions.
- **`KeychainStore`** keeps items as generic passwords (service `pistachio`, account = item ID). Kind, agent-safe,
  service and "used in" are JSON in `kSecAttrGeneric`; the note is `kSecAttrComment`. `.iCloud` mode uses the
  data-protection keychain with `kSecAttrSynchronizable` in the app's access group; `.thisMac` uses the login
  keychain. `KeychainStore.automatic` picks by trying a write (reads from an unentitled process just say "not
  found").
- **`SystemApprover`** uses LocalAuthentication. The app's `PanelApprover` shows every question in one panel with
  Touch ID inside it (`InlineTouchID`), groups questions with the same `ApprovalRequest.caller` and folder
  (`Approver.groupsRequests`), and keeps the system sheet for Use Password…. `Broker.handle` asks outside its lock in
  two passes: the first records the question (`decide`), the second uses the answer only if `Broker.covers` it and
  no item's value changed.
- **Inline Touch ID** (`InlineTouchID` in MainWindow.swift) is the system's `LAAuthenticationView` at its small size
  (32 pt; the sizes are fixed, and a scaled one stops drawing and evaluating). The approval panel is a non-activating
  `NSPanel` and starts Touch ID as soon as it's on screen (`needsKeyWindow: false`); the lock screen starts only in a
  key window and stops when its window loses the keyboard, so it can't take a touch meant for a panel. Each start and
  end is logged under `io.snackstud.latchkey` / `touchid`, with no values or reasons:
  `log show --last 10m --predicate 'subsystem == "io.snackstud.latchkey" AND category == "touchid"'`.
- **`PeerInfo`** reads the caller's PID, working folder and command line from the kernel and walks parent processes.
  **`CodeIdentity`** checks code signatures through the socket's audit token: the app recognizes its own tool
  (`io.snackstud.latchkey.cli`), and the tool refuses to talk to anything but the app (`io.snackstud.latchkey`), both
  signed by the same team. `pst status` shows what each side saw. Requests carry no folder or command of their
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
from `pst mcp`: approval panels say an agent asked, and grants it asks for are limited (`Broker.grant`).

The CLI target holds `main.swift` (commands), `Run.swift` (filling in an environment and masking output, shared by
`run`, `check` and the MCP server) and `MCP.swift` (`pst mcp`: JSON-RPC over standard input and output).

## Stored identifiers

Signing identities, access groups, keychain services, container locations and purchase IDs are persistent
contracts. Display-name changes must not change them: doing so can orphan existing items, grants, history,
logs or purchases. The broker verifies callers against the same signed identities.

The exact values are defined in the [project configuration](../App/project.yml),
[stored-identifier checks](../Tests/LatchkeyCoreTests/StoredIdentifierTests.swift), and
[packaging checks](../scripts/tests/test_stored_identifiers.py). Those checks fail on accidental changes.
Use these source definitions for diagnostics and release configuration; do not derive identifiers from display names.

## Adding a remote service

Add a case to `RemoteTarget.Service`, then fill in `label`, `tool`, `problem` (required fields), `isProduction`,
`pushCommands` (values on standard input only), `listCommand` and `names(fromListOutput:)` (keep names, drop values).
Add tests in `RemoteTests.swift` with `FakeRunner`; no test should run a real tool.

## Regression checks

```bash
swift test
node --test App/Safari/*.test.js
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py'
```

The `LatchkeyRunTests` target tests command preparation without contacting the real app: proxy refusal,
key-file isolation, permissions and cleanup, and malformed env-file handling. Core tests cover one-request
approvals, command/session/use-limited grants and immediate revocation, multiline import/rewrite, changed-file
protection, and URL redaction. Safari tests use detector fixtures and a small DOM fixture, not real pages or keys.
The loopback proxy test needs permission to bind a local listener; real-keychain and AWS network tests remain
opt-in. App compilation and these tests do not replace signed-app, real-Safari or cross-device sync verification.

The wire response keeps the optional legacy `remembered` field for older clients; new brokers never return it.
The old read-approval preference and `PISTACHIO_APPROVAL_WINDOW` have no effect. Explicit grants provide repeat access.

## Sandbox development

See [App Store preparation](app-store.md) for the separate experimental configuration, Apple SDK choices,
security-scoped access and submission gates. Full developer functionality remains the target; an unsigned
compile does not establish runtime sandbox compatibility.

## Checking the UI without clicking

Debug builds can draw their own UI to a PNG:

```bash
build/DerivedData/Build/Products/Debug/Latchkey.app/Contents/MacOS/Pistachio \
  --snapshot out.png [--sample] [--select ID,...] [--filter all|activity|grants|project:NAME] \
  [--part sidebar|menubar|approval|list|bulk|move|grant|detail|deleted|remote|pushapproval] -ApplePersistenceIgnoreState YES
```

Snapshot startup uses an in-memory broker and skips the live Keychain, migration, background service and updater.
`--sample` fills the view with examples; without it, the fixture starts empty. `--part` draws one view off screen
(more reliable than the whole window when started from a shell).

Add `--appearance light` or `--appearance dark` to draw in that theme instead of the system's.

Use `--settings general|privacy|storage|developer|membership|about --part settings` for one Settings tab, or
`--settings privacy --part settings-window` for the tabbed window (off screen, the tabs draw as a segmented control).
Native sidebar materials may be absent from an off-screen full-window capture; `--part sidebar` renders that
component independently. These previews do not exercise real App Store purchases or login-item registration.

## Service icons

The sidebar's service icons are in `App/Latchkey/Assets.xcassets/ServiceIcons`, one image set per service, named as
`Services.swift` spells it. `scripts/fetch-service-icons.py` fetches any that are missing from each service's own site
(its `apple-touch-icon` or `icon` link, else `/favicon.ico`) and converts them to 64×64 PNG; add a new service to its
`SITES` list, run it, and look at the images before committing. The app never fetches icons.

## The logo and icon

`App/Branding/pistachio.svg` is the supplied three-piece color mark; `pistachio-template.svg` is its monochrome
menu bar counterpart. `App/Branding/logo.svg` retains the original key. Service/provider icons are unchanged.

General settings offers **Pistachio** and **Key**. The `appIconChoice` preference is stored locally and defaults to
Pistachio, including for malformed values. It updates the running Dock icon through AppKit’s
`NSApplication.applicationIconImage`, the template status item, and the marks in the app, approvals and What’s New.
The choice is reapplied on launch; it changes no broker policy, credentials, bundle IDs or signed bundle files.
Finder and Safari retain the bundled Pistachio icon. macOS does not provide this running-app preference as a Finder
icon choice; do not write Finder custom-icon metadata or modify the signed application bundle to simulate it.

`App/Latchkey/AppIcon.icon` is the default Icon Composer document, with three separate Pistachio layers and light/dark
backgrounds. Key/Pistachio Dock alternatives and Safari’s 48/96/128px icons are generated from checked-in vectors by
`swift scripts/brand-icons.swift`, through the register. The runtime image sets include light and dark appearances.
`Logo`/`MenuBarIcon` remain the key assets; `PistachioLogo`/`PistachioMenuBarIcon` are the supplied mark. `LogoMark`,
`BrandAppIcon` and `AppBranding` centralize the presentation choice. The website’s branding is maintained separately
in its website worktree; see [site.md](site.md).


## Conventions

- Never deliberately write stored values to logs, errors or test output. `pst get` prints values; child
  output masks exact copies only. Command arguments use heuristic redaction, so keep values out of arguments.
- Every change to items goes through the broker, so it's approved and logged.
- Tests use `MemoryStore`, `MemoryVersionStore`, `MemoryRemoteStore`, `FixedApprover` and `FakeRunner`; nothing
  touches the real keychain unless `LATCHKEY_KEYCHAIN_TESTS=1`.

## CLI command names

`pst` is the short command; `pistachio` is the full name. The app installer, development installer, standalone
archive and both Homebrew packages provide them. SwiftPM exposes both products from the same executable target.
See [cli.md](cli.md) for command behavior. Signing, storage and protocol details follow the checked-in source;
branding edits do not change those boundaries.
