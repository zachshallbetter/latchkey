# Contributing

Thanks for helping. Latchkey is a macOS secrets manager, so changes are held to one rule above the rest: a stored
value never reaches a log, an error, test output or a command argument. [docs/development.md](docs/development.md)
is the canonical guide to the layout, the wire protocol, building and testing; this page is the short version.

## Setup

You need macOS (the command-line tool needs 14 or later, the app 15 or later), a Swift toolchain, Node for the Safari
extension's tests, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build the app.

```bash
swift build
swift test                                  # unit tests
node --test App/Safari/*.test.js            # the Safari extension's tests
cd App && xcodegen && open Latchkey.xcodeproj
scripts/install.sh                          # build Release, install the app and CLI, restart the app
```

`swift test` uses in-memory stores and never touches your keychain. `LATCHKEY_KEYCHAIN_TESTS=1 swift test` also
round-trips through your real login keychain; it is opt-in. See
[Development](docs/development.md#building-and-testing) for signing and the broker-only development build.

## Conventions

- Never deliberately write stored values to logs, errors or test output. Keep values out of command arguments.
- Every change to items goes through the broker, so it is approved and logged.
- Tests use `MemoryStore`, `MemoryVersionStore`, `MemoryRemoteStore`, `FixedApprover` and `FakeRunner`; no test runs
  a real remote tool or touches the real keychain.
- A new caller identity, broker gate, socket or system of record changes the trust boundary. Open an issue to
  discuss it before writing code.
- Update the docs and the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md) with the change.
- Commit and PR titles are short sentences in the imperative or descriptive present, with no required prefix,
  for example "Settings gets its own tabbed window". Pull requests are merged by the maintainer.

## Before you open a pull request

Run `swift test` and `node --test App/Safari/*.test.js`. CI runs `swift test` on pull requests that touch
`Sources/`, `Tests/` or `Package.swift`. For app changes, also build the app; those builds are not covered by CI.
The pull request template asks what you ran.

## Coding agents

If you use a coding agent, point it at [AGENTS.md](AGENTS.md), the operating contract for this repository.

## Security

Report vulnerabilities privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.
