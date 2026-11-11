# Coordinator grants through ACP

A coordinator agent can give its sub-agents read access to specific Latchkey items, for one repository and a
limited time, without the owner approving each one. ACP (acp-gateway) decides, from the owner's signed policy;
Latchkey enforces limits the owner set once, and records every use.

This document is the contract between the two. The Latchkey side is built; the ACP side is specified here.
ACP is the owner's own tooling: the integration is off unless trusted on a Mac, and nothing about it shows in the
app until then.

## Flow

```
sub-agent ── latchkey run … ──► Latchkey: refused (exit 77), no grant
sub-agent ── POST /internal/authorize {action: "secret.read", …} ──► ACP
ACP ── policy: governed repo, verified trust, Ready ticket, coordinator may delegate these items ──► ALLOW + capability
sub-agent ── latchkey grant --capability TOKEN ──► Latchkey
Latchkey ── signature, audience, key, expiry, single use, owner's limits, repository ──► ok
Latchkey ── POST /internal/verify-capability ──► ACP: valid (and consumed)
Latchkey ── grant for the items, the repository's checkout and its worktrees, ≤ the owner's limit ──► sub-agent runs
```

## The owner's setup (once per Mac)

    latchkey set ACP_GATEWAY_TOKEN                 # the gateway bearer, for the validity check
    latchkey acp trust https://acp.example --key-id lk-1 --public-key <base64> --gateway-token-item ACP_GATEWAY_TOKEN

Defaults: development and preview only, at most 2 hours per grant. Production is refused outright, in the
trust record and in every capability. Trusting asks for Touch ID. The trust record is a keychain item in the
signed app's access group, not synced: only Latchkey can change it, and trusting ACP on one Mac doesn't reach
another. `latchkey acp untrust` (or **Stop Trusting ACP** in Settings) ends every ACP grant at once.

ACP grants are read-only. Changes, deletes, history, restores and pushes still need the owner.

## The request to ACP

A new action, `secret.read`, in the existing `/internal/authorize` shape:

```json
{
  "agent_id": "sub-agent-7",
  "actor_id": "github-user:12345",
  "session_id": "optional",
  "repository_claim": {"owner": "me", "name": "acp-gateway", "remote_url": "…", "head_sha": "…"},
  "action": "secret.read",
  "context": {
    "items": ["acp-gateway/development/*"],
    "duration_seconds": 3600,
    "work_item": "LAT-42",
    "coordinator_id": "coordinator-2",
    "audience": "latchkey"
  }
}
```

- `items`: Latchkey item IDs (`project/environment/NAME`) or environment patterns (`project/environment/*`).
  Never a whole project (`project/*`) and never a shared item. At most 32 entries, each at most 192 characters.
- `duration_seconds`: 60 to 604800. Latchkey caps it further at the owner's limit.
- `work_item`: the ticket. ACP should require it Ready, as for `database.migrate`.
- `coordinator_id`: who is delegating. Like `agent_id`, recorded for audit; the policy decides whether that
  coordinator may delegate these items for this repository.

Policy additions on the ACP side: which repositories and environments `secret.read` may cover, which coordinators
may delegate, and the longest duration. Suggested class: `delegated` (requires `VERIFIED` trust; no recovery
authorization).

## The capability

On `ALLOW`, the response carries `latchkey_capability`: `base64url(payload) "." base64url(signature)`, no padding.
The signature is **Ed25519** over the exact payload bytes, with a key used only for Latchkey capabilities
(suggested variable `ACP_LATCHKEY_SIGNING_KEY`; publish its public key and id). ACP's existing capabilities are
MACs; this one must be asymmetric, so Latchkey can check a capability without being able to make one.

Payload (JSON, UTF-8):

| Field | Meaning |
|---|---|
| `v` | `1` |
| `aud` | `"latchkey"` |
| `kid` | the signing key's id; Latchkey refuses any other |
| `jti` | unique id, used once |
| `iat`, `exp` | issued at, redeem by (seconds since 1970). Suggested `exp` = `iat` + 300 |
| `sub` | the agent it's for (`agent_id`) |
| `act` | the delegating coordinator (`coordinator_id`) |
| `ticket` | `work_item` |
| `repository` | `{"owner": "…", "name": "…"}`, as ACP verified it |
| `items` | as requested, after policy (ACP may narrow, never widen) |
| `duration` | seconds the grant lasts once redeemed |
| `request_id` | the authorize request's id, for joining audit records |

## The validity check

Latchkey calls `POST /internal/verify-capability` with the gateway bearer and `{"capability_token": "<the
latchkey capability>"}` before it grants anything. ACP answers `{"valid": true}` or `{"valid": false, "reason":
"EXPIRED" | "REVOKED" | "CONSUMED" | "SIGNATURE_INVALID" | "STATE_CHANGED" | …}`, as it does for its own
capabilities, and consumes the capability on a valid check. Incrementing a repository's `security_version`
should invalidate outstanding Latchkey capabilities the same way.

If ACP can't be reached, Latchkey refuses: revocation has to work, and a grant is never more than a short wait
away.

## What Latchkey checks

1. ACP is trusted on this Mac.
2. The signature verifies with the trusted public key; `aud` is `latchkey`; `kid` matches; `exp` hasn't passed.
3. Every entry in `items` is an item ID or environment pattern in an environment the owner allowed, and none is
   production.
4. The `jti` hasn't been redeemed here before.
5. The command runs inside a git repository whose `origin` is `repository`.
6. ACP confirms the capability is valid.

Then the grant: the items, for the repository's main checkout and all its worktrees, for `min(duration, the
owner's limit)`. It's labelled as ACP's in the window, and every read through it records the agent, ticket and
coordinator in Activity. A refusal at any step is logged with its reason and exits 77; the agent should ask its
coordinator or the owner, not retry the same capability.
