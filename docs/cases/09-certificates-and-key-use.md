# Case 09: Handle certificates, keys and signing without unnecessary file copies

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Problem

Moving machines and setting up agents may require certificate chains, private keys, SSH credentials or signing material. A certificate generally contains public identity-binding information; the sensitive part is usually its associated private key.

## Desired flow

- Distinguish public certificate, exportable private key, non-exportable key and provider-issued token.
- Import an existing private key where appropriate, with explicit consent, ownership and intended use metadata.
- Allow a program to use protected key material through a supported signing/authentication interface **without exporting it**, when the OS/protocol supports this.
- When a tool truly requires a key file, issue an ephemeral permission-restricted file with visible exposure limits and deterministic cleanup.
- Device-bound hardware keys may need separate enrollment on each Mac; do not claim they synchronize as private keys through iCloud.

## Tests / guardrails

- Never silently treat a certificate as a secret or assume all private keys are exportable.
- Temporary material is permission restricted, short lived and not placed into logs or repository files.
- Authenticate intended caller and bind authorized signing operation where possible.
- Explain the unavoidable exposure when external tools demand plaintext key files.

## Current evidence

`docs/agents.md` and `docs/security.md` describe temporary key-file delivery. `docs/apple-passwords-and-passkeys.md` identifies Secure Enclave SSH-agent work as **planned**, and notes device-bound keys do not sync. Native non-exportable key operation is not established as shipped.
