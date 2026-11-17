# Project Intent

**Project ID:** `latchkey`
**Project Name:** `Latchkey`
**Status:** Active

Provenance: synthesized at bootstrap adoption (2026-11-17) from [README.md](../../README.md),
[docs/security.md](../../docs/security.md), [docs/app-store.md](../../docs/app-store.md),
[docs/releasing.md](../../docs/releasing.md) and the owner's recorded pricing and App Store decisions. Those documents
remain the authority for what they describe; this file summarizes them and does not override them.

## Originating intent

Developers keep secrets in `.env` files and hand them to coding agents that can read anything in the folder.
Latchkey is a secrets manager for Macs and the agents that run on them: project files keep `latchkey://` references,
the values stay in iCloud Keychain, and a command gets them only when it starts and only after the owner approves
(Touch ID or a grant). It counts when values leave files, follow the owner to every Mac, and reach an agent only as
far as the owner has allowed, with every read and change logged without values. A build that works but lets a value
reach a file, a log, an argument or an agent without approval does not count.

## Desired state

```text
Secrets in .env files, readable by any program or agent in the folder
      ↓
One process (the app) holds values; the CLI, MCP server and Safari extension ask it
      ↓
Signed, notarized direct download and Mac App Store releases whose approvals,
grants, history and sync are verified on real Macs
```

## Constraints

- **Values:** never written to logs, errors, test output or command arguments; the CLI never touches the keychain;
  every change goes through the broker, approved and logged ([docs/security.md](../../docs/security.md)).
- **Pricing:** storing, reading and exporting your own values never depend on Pro. Pro is a one-time App Store
  purchase; the direct download is free.
- **Licensing:** Functional Source License 1.1 (Apache 2.0 after two years). The owner is the only author.
- **Platform:** CLI on macOS 14 or later, app on macOS 15 or later. The App Store build is sandboxed and leaves out
  what the sandbox can't support (GitHub Actions pushes, Chrome).
- **Releases and spend:** the website deploys manually; hosted builds never run on every push. Signing, notarization,
  App Store submission and production deploys are the owner's.
- **New trust boundaries:** a new caller identity, broker gate, socket or system of record is proposed and approved
  before code.

## Non-goals

- Holding credentials hostage to sell upgrades.
- Team or shared vaults (a separate later product).
- Storing values anywhere but the keychain, or syncing them through anything but iCloud Keychain.
- Platforms other than macOS.

## Success questions

At maturity, canonical state should answer:

```text
What is true?
What is authoritative?
What is unresolved?
What is Ready?
What is blocked and why?
What evidence supports current claims?
What effects are currently allowed?
What requires a human decision?
```

## Termination / dormancy

Latchkey moves to routine operation once the direct download and the Mac App Store version are released and their
remaining verification issues (real-site Safari fill, cross-Mac sync, signed-app runtime checks) are closed.
