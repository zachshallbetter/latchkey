# Case 06: Treat credentials as managed objects with lifecycles

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Need

A name/value pair alone cannot express purpose, owner, provider, environment, privilege, creation date, expiry, revocation, rotation requirements, title, usage history and dependencies. A credential may be valid, expired, revoked, unknown or never tested.

## Proposed fields / behaviors

- Human-friendly title and service identity; project and local/preview/staging/production bindings.
- Provider/account scope and permitted operations **when known**.
- Created/imported/last-rotated and explicit expiration dates with evidence source.
- Status values such as `unknown`, `reported-expired`, `provider-verified-valid` and `revoked`, avoiding conflation.
- Dependency graph of known references, providers and remote environments; uncertain or undiscovered uses are marked.
- Warnings before expiry and rotation, reconciliation for stale entries, review before purge, and a record of what was affected.

## Example acceptance

A key named "Payments staging" is due to expire. Latchkey can identify known consumers, alert the owner, propose rotation and assist replacement/push only under appropriate authority. If the provider exposes no reliable expiry API, status remains unknown rather than inventing one.

## Current evidence

The repo documents service, kind, project/environment, history, recently deleted, `touched`, rotation assistance and remote links. Provider-backed validity checking, expiration monitoring, full dependency mapping and comprehensive lifecycle classification are **not established** by the existing documentation.
