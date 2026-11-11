# Case 07: Observe credential use and possible exposure

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Need

An owner should be able to answer: which local command or agent requested this credential, for what project, when, which remote destination received it, and what may have been exposed? These are separate evidence questions.

## Evidence classes

1. **Local Latchkey observation:** broker reads, approvals, grants, changes, imports and pushes. This records access via Latchkey, not every subsequent network request.
2. **Provider observation (future where APIs permit):** provider-side last-used, token scope, expiration, revocation or activity. Availability and accuracy vary.
3. **Exposure indicators (future):** known plaintext config files, local Git history, pasted output, accident reports and provider alerts. Scans must not exfiltrate or print secrets.
4. **Unknown/unobservable:** a value used outside Latchkey, derived/transformed disclosures, copies retained by child processes, or consumption on systems not reporting back.

## Acceptance / safety

- Activity must state whether an event means **requested**, **released**, **proxied**, **pushed**, **observed at provider** or **confirmed compromised**.
- Logs contain no deliberate values, and redaction limitations remain explicit.
- Rotation advice identifies known consumers and the difference between exposure suspicion and confirmed compromise.
- Monitoring should avoid creating another database of reusable credentials.
- HMAC chaining can detect some log tampering, but it is not a guarantee of complete logs or malware resistance.

## Current evidence

`docs/security.md` describes broker logging, HMAC chains, proxy limitations and exact-value masking. `docs/agents.md` describes `latchkey touched`. Neither is comprehensive provider usage monitoring or proof of non-exposure.
