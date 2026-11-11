# Case 02: Absorb an env file; replace values with vault addresses

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Problem

Applications already depend on `.env` files. Their simplicity is valuable, but literal secrets do not need to remain embedded in those files after they are ingested. The goal is **not** to ban agents from reading/writing config files, nor to eliminate the application env interface.

## Desired flow

Input:
```dotenv
DATABASE_URL=postgres://example:example@localhost/test
STRIPE_SECRET_KEY=example-not-a-real-key
```

Import with a reviewed plan:
```sh
latchkey import .env.local --dry-run
latchkey import .env.local --rewrite
```

Afterward:
```dotenv
DATABASE_URL=latchkey://shop/development/DATABASE_URL
STRIPE_SECRET_KEY=latchkey://shop/development/STRIPE_SECRET_KEY
```

Launch:
```sh
latchkey run --env-file .env.local -- npm test
```

The file expresses which credentials the application requires. The vault holds values; the launcher resolves them for the consumer when approved. An agent may maintain these **references and other nonsecret configuration** in an env file. Explicit plaintext delivery is still possible when a target has no reference-aware entry point, with its exposure made clear.

## Acceptance / edge cases

- One file or a scanned collection of projects; dry-run shows identifiers, counts, skips and conflicts, not literal values.
- Existing files, multiline quoted values, comments, permissions, changed-file detection and interrupted rewrites receive safe handling.
- A successful import must not rewrite to a reference that cannot be recovered; partial failure must be explainable and retryable.
- Existing references and empty values are handled correctly; unexpected duplicate IDs with different values are not overwritten without explicit choice.
- A missing vault item is a visible missing dependency, not an excuse to seek a secret from Git or silently invent one.

## Current evidence

`docs/import.md` describes import, scan, rewrite, default skips, sharing, conflict detection and limitations. `docs/agents.md` describes `run` and env-free runs. Tests are described in `docs/development.md`; end-to-end app behavior has not been independently exercised in this documentation pass.
