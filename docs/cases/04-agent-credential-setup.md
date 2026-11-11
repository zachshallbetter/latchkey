# Case 04: Let an agent set up and use an API without manual token handoff

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Problem

An agent can write an integration and its tests but stalls when it needs an existing or newly issued API credential. The owner should not have to search a password manager, copy a value, run a script or paste it into an env file on every request.

## Desired flow

1. Agent identifies the service, environment and action it needs; looks up available **names and metadata**.
2. If an appropriate credential exists, agent requests a limited use or a time-/session-/command-bounded grant.
3. If missing, agent may initiate a supported provider-specific issuance flow when authorized; provider-required interactive authentication or MFA remains human-controlled.
4. New credential is captured into the vault, with its identity, provider, scope and any known expiration. The agent writes the `latchkey://` reference into project config.
5. Agent runs a permitted command through `latchkey run` or a mediated provider integration; verifies result and reports what changed.
6. Agent cannot autonomously broaden privilege, obtain production access by asking for a development credential, or rotate/revoke credentials merely because it may use them.

## Existing vs future

Current docs describe `lk mcp` for status/list/check/run/request-grant, `latchkey run`, bounded grants and no direct MCP secret-read tool. Generic provider token **creation/provisioning and auto-linking** are proposed design work, not proven shipped behavior. Some operations still supply raw values to child processes.

## Acceptance / guardrails

- Identity of human owner, requesting agent/process, requested operation and specific granted scope stay distinguishable.
- Permissions to **use**, **create**, **write references**, **rotate**, **push** and **revoke** are separately considered.
- A refusal/missing item ends the workflow without repeated approval-spam or printing the secret.
- Interactive challenges are surfaced rather than bypassed.
- The result contains proof of requested integration behavior without secret content.

## References

`docs/agents.md`, `docs/security.md`, `docs/remote.md`.
