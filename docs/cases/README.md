# Latchkey use-case register

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Origin

The initial problem arose while migrating development work to a new Mac. Git repositories cloned readily, but ignored `.env` files, API credentials and private keys did not. Some values were expired, duplicated, stale or deliberately kept out of source control. Manually transferring or reconstructing them was unwanted. The interaction model of Apple Passwords / 1Password suggested portable, protected credentials referenced by projects rather than copied into them.

A second problem arose with coding agents: agents could implement integrations but stopped to ask a human to locate, paste or manually provision a token. The goal is **controlled, usable access**, not preventing all agent activity or eliminating env files.

## Cases

| Case | Primary question | Evidence/status |
|---|---|---|
| [01 Cross-Mac recovery](01-cross-mac-migration.md) | Can a cloned project use existing credentials on a new Mac? | Keychain sync documented; clean-device E2E not proven |
| [02 Absorb and rewrite env](02-env-absorption-and-references.md) | Can existing files be ingested and replaced with stable references? | Import/rewrite implemented per docs |
| [03 Shared credential](03-shared-credential-dependencies.md) | Can multiple projects intentionally reuse one value without copying it? | Shared items/import option documented; authority still shared |
| [04 Agent setup and use](04-agent-credential-setup.md) | Can an agent configure and use a service without making a human copy values? | Run/MCP/grants documented; general provisioning is future work |
| [05 Capture at source](05-browser-cli-capture.md) | Can a one-time token be captured from Safari or a CLI? | Safari capture documented; general CLI capture proposed |
| [06 Lifecycle and metadata](06-credential-lifecycle.md) | Can credentials be identified, rotated and retired with useful context? | Partial metadata/history/rotation; provider health is proposed |
| [07 Exposure and observability](07-usage-and-exposure.md) | Can uses and possible disclosure be understood? | Local access log and touched documented; provider/exposure coverage limited |
| [08 Custody and delegated authority](08-custody-and-delegation.md) | Does approval actually constrain what an agent can do? | Multiple modes; enforcement limits explicit |
| [09 Certificates and private keys](09-certificates-and-key-use.md) | Can a tool use identity material without copying a private key? | Key-file delivery documented; non-exportable key use proposed |

## Cross-cutting design rules

1. Preserve the environment-variable interface where applications require it; env files may contain references or explicitly delivered values. Never claim env files must disappear.
2. Prefer stable references (for example `latchkey://shop/production/DATABASE_URL`) over duplicate literal secrets in repositories.
3. A reference is an identifier, **not** proof of permission or validity. Names, dependencies and security classifications need not imply that the underlying provider has confirmed them.
4. Distinguish **stored**, **synced**, **resolved**, **released**, **proxied**, **rotated**, **revoked** and **actually used at a provider**.
5. Distinguish human owner, requesting process/agent, delegation, policy decision and executed operation. Approvals must not be presented as constraints the execution path cannot enforce.
6. Shared references reduce duplicated secret distribution, not the authority shared among consumers.
7. Treat iCloud Keychain as platform-backed custody and sync, not as the Apple Passwords application's own database. Latchkey has its own access group.
8. Never treat a successful build or documentation claim as proof of cross-device delivery, signed sandbox behavior or resistance to compromise.
9. When importing, editing, monitoring or scanning, avoid placing literal values in Git, logs, command arguments, reports or agent context.

## Product provenance and verification

Relevant existing docs: [README](../../README.md), [import](../import.md), [agents](../agents.md), [security](../security.md), [development](../development.md), [remote locations](../remote.md), [Apple Passwords / passkeys](../apple-passwords-and-passkeys.md), [App Store readiness](../app-store.md).

No secrets or credentials are stored in this register. Cases should become issues or tests only after comparing with current code and owner priorities.
