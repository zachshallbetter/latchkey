# Latchkey boundary for proposed Authority Manifest

Status: **design proposal** (2026-11-11). This document does not introduce a shipped CLI command, MCP tool, or authority manifest parser.

Upstream conceptual specification and vertical slice: [ACP Gateway design](https://github.com/zachshallbetter/acp-gateway/blob/docs/authority-manifest-staging-slice/docs/AUTHORITY_MANIFEST_PROPOSAL.md).

## Why this belongs near Latchkey

A project's secret identifiers and environment definitions may express **what resources it needs** without carrying values. A separate, untrusted authority requirements manifest can express **what operations it proposes** without conferring permission. Latchkey is responsible for custody and approved credential access; ACP Gateway is the source of policy decisions; provider adapters enforce what the provider can actually guarantee.

This is a generalization of the motivation for Latchkey: stop requiring a developer to move a credential whenever an agent needs to perform authorized work. It does **not** turn Latchkey into a policy-decision service.

## Product contract to test before coding

For a request like `deploy shop at immutable SHA 73a1... to staging`:

1. Agent reads a project manifest that names `deploy-staging`. The manifest does not contain credential values, privileged tokens or the owner's grant.
2. Latchkey may list **credential metadata** and match candidate project/environment references without disclosing values. Being available is not being authorized.
3. ACP authenticates the actor and independently decides the exact operation under server-side policy. A manifest cannot modify this policy.
4. A provider-specific execution adapter checks the decision binding, target, scope and anti-replay requirements; it may request a credential from Latchkey through a **mediated** path only after its separate identity and authorization are verified.
5. Adapter reports whether it can actually constrain deployment to staging and the designated revision. Unsupported restrictions must be refused or require visibly broader approval.
6. Evidence distinguishes requested, authorized, submitted and observed effects.

## Existing Latchkey behaviors that are NOT substitutes for the above

- `latchkey://` references name credentials but are not grants.
- `latchkey run --env PROJECT/ENV` supplies plaintext to a child process; a child with the value can exercise its provider-side permissions.
- `latchkey run --proxy` for supported AI providers conceals the upstream API key from the child while accepting requests with a placeholder. That is a bearer capability and does not enforce arbitrary operation-level policy.
- `--aws-session` gives temporary credentials; short-lived does not automatically mean narrow.
- Local grants and broker audit are useful, but do not constitute remote execution evidence or a cross-system approval proof.
- `usedIn` imported file paths are partial dependency signals, not global consumer discovery. Paths may vary between Macs.

See [security](security.md), [agents](agents.md), [CLI](cli.md), and [import](import.md) for implemented behavior and limits.

## Latchkey-specific proposed work

- [ ] Specify a metadata-only matching response: stable item ID, intended project/environment/service, availability state, known scope if provider verified, freshness/source and conflicts; never include raw values in this response.
- [ ] Formalize project/environment definitions and reference export so a fresh checkout can reconstruct required credential names, including shared mappings, without depending on original absolute paths.
- [ ] Distinguish *match*, *credential release*, *proxied request*, and *mediated action* in grants and logs.
- [ ] Define a credential-use interface for independently authorized adapters with strong requester identity and explicit constraints. Do not allow a caller to turn an ACP `ALLOW` string into automatic secret retrieval.
- [ ] If a provider adapter cannot prevent a production operation while using a broad token, report **cannot enforce**; no raw token fallback to an arbitrary agent.
- [ ] Test revocation, rotation, permission changes, expiry, missing metadata, disconnected ACP, and attempted alternate-target execution.
- [ ] Test clean-Mac project reconstruction as a separate portability requirement, not a side effect assumed from Keychain sync.

## End-to-end smoke scenario

A developer clones `shop` on another Mac. Latchkey can resolve the named development/staging credential records if properly synchronized and configured. The agent requests `deploy-staging` for one immutable revision. ACP evaluates against policy. Only the vetted adapter receives access necessary to execute. A mismatch in revision, target, actor, approval lifetime or enforceability blocks the attempt. The user sees an evidence trail without secret values.

## Publication relationship

- **The Credentials We Learned to Copy**: why a project should describe credential dependencies without storing their values.
- **The Authority a Project Carries**: what permission a project requests and what authorization is actually granted.
- **The Difference Between Permission and Proof**: how enforcement and evidence differ from an approval decision.

Do not retrofit the first article into a protocol announcement. Use the staged deployment example for the second essay.
