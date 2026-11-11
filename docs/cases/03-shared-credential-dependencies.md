# Case 03: Share one credential across several projects, visibly

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Reality

Developers sometimes reuse provider credentials among projects, whether intentional, historical or expedient. Copying identical values into several env files makes rotation and dependency discovery difficult. The product should represent real-world reuse rather than pretend it never occurs.

## Desired flow

Project A, B and C each have `OPENAI_API_KEY=latchkey://shared/openai/PRIMARY_KEY`. There is one vault record, multiple configuration references and potentially distinct per-caller approval policies. Rotation updates the vault item, so references need not change.

## Acceptance / tests

- Show known referencing files/projects/environments, including uncertainty about copies that exist outside Latchkey.
- Detect identical imported values and **offer or explicitly request** consolidation; never merge credentials with different scopes solely because their displayed names match.
- Rotation and deletion show affected known consumers before action.
- A grant to Project A must not automatically allow the same credential to be retrieved by Project B.
- Warn when production, preview and local projects share an unusually privileged key; distinguish intended sharing from accidental sharing.

## Security limit

One vault copy reduces unnecessary at-rest duplication. **If multiple consumers receive the same bearer token, they still share its service-side authority.** Compromise of any consumer may disclose it. Better visibility makes it easier to migrate to per-service or restricted credentials; it does not erase that risk.

## Current evidence

`docs/import.md` documents `--share-identical`; `docs/concepts.md` and `docs/agents.md` document project/environment identities and grants. Comprehensive dependency discovery across unknown external copies is not established.
