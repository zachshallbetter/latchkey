# Case 01: Rebuild a development machine without copying credentials

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Trigger / actual origin

An owner moves development work to a new Mac. Pulling Git repositories is easy, but secrets in ignored env files, certificates/private keys and integration configuration are not tracked in Git. Some are expired, obsolete or shared. The owner does not want to send sensitive files over the wire or manually recreate every project's environment.

## Desired behavior

1. On the original Mac, import project credentials into Latchkey and replace the relevant literals with references.
2. Store secret values in Latchkey's own iCloud Keychain access group, preserving service/project/environment identity.
3. On the other Mac, install a compatible signed Latchkey app, sign in to the appropriate Apple Account and allow keychain sync.
4. Clone repositories, use references or `latchkey run --env PROJECT/ENV`, and resolve keys under local approvals/grants.
5. Report missing, conflicting, expired-known and unverified values instead of guessing or silently defaulting.

## Acceptance / tests

- Clean Mac A -> Mac B exercise with actual signing, entitlement and sync verification, including reinstallation, device lock and no Touch ID.
- Reference resolves on B without plaintext export or credentials committed to Git.
- Local grants do **not** silently synchronize as global permission; each device controls its local trust decision.
- A key marked obsolete/expired by reliable evidence is not silently treated as valid; unknown provider state remains unknown.
- If sync is delayed or unavailable, show a useful, safe error, not a fallback to an unexpected empty vault.

## Status and caveats

`README.md` and `docs/apple-passwords-and-passkeys.md` document iCloud Keychain-backed storage, distinct access groups and same-team signing. `docs/app-store.md` still lists clean-machine sync/migration proof as outstanding. iCloud transport is not an agent-access authorization system, and a synchronized credential can still have been revoked by its provider.
