# Case 08: Keep custody, authorization and execution distinct

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Question

An owner approves an agent to deploy **project A, revision 73, to staging**. The underlying deployment token may permit production changes and access to other projects. The intended authority is narrower than the credential's privileges.

## Three operating modes

1. **Credential retrieval:** caller receives the secret, then exercises its full service-side permissions. Latchkey can control retrieval, not subsequent behavior.
2. **Mediated use:** an intermediary holds the value and performs a requested action. This reduces exposure but is only as safe as the mediator's permitted operations.
3. **Constrained delegation:** a provider issues narrower credentials, or a trusted enforcement boundary executes an operation within limits it can actually enforce. Not universal.

## Desired enforcement test

- Record who authorized, which process/agent requested, exact target and revision, policy result and expiry.
- Bind the authorization to execution; do not allow swapping project/environment/revision after approval or replaying authorization for another actor.
- Verify the operation submitted, and separately record the observed result (success does not prove correctness).
- If the service cannot support a claimed narrow restriction, refuse, require explicit broader approval, or state the limitation plainly.
- Deliberately consider broker compromise: consolidating credentials concentrates possible authority and requires isolation and review.

## Latchkey / ACP boundary

Latchkey is the credential custodian and an access/operation mediator. ACP Gateway is a possible policy/coordination participant. **The systems' integration and enforcement guarantees must not be assumed from their descriptions.** A policy decision cannot enforce a requested action unless the component holding/using the credential honors it.

## Current evidence

`docs/security.md` documents value delivery, grants, a key proxy for specified providers and short-lived AWS STS credentials. `docs/agents.md` describes scoped operations and explicit limits. Complete end-to-end delegation or narrow execution for arbitrary provider APIs is not claimed.
