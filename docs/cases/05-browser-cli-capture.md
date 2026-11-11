# Case 05: Capture credentials where they are issued

These cases preserve the product reasoning captured on 2026-11-11. They are user needs and acceptance criteria, **not claims that every behavior ships today**. "Current evidence" refers to repository documentation on main as reviewed on that date, not independent runtime verification. Never add a real secret to a fixture or documentation.

## Problem

A provider dashboard displays a key once; a CLI prints a newly generated credential; a person copies it to a file. Manual transfer is both inconvenient and a disclosure opportunity.

## Browser flow

On an allowed Safari page, detect a plausible newly displayed token without broadly scraping passwords. Offer **Save to Latchkey** beside the value or via explicit selection; obtain consent before sending the value to the app. Record provider/environment/project context if established. Do not treat an uncertain DOM guess as a verified credential identity. Allow per-item fill sites under HTTPS and fresh approval.

## CLI flow (proposed beyond current documented import)

Provide a deliberate, command-aware way to capture output from supported credential-issuance commands **without embedding secrets in shell arguments, history or routine logs**. Many tools print tokens to stdout or use human-driven browser auth: wrapping a command does not retroactively prevent that output. Prefer provider integrations/API responses or explicitly consented capture; treat terminal output interception as risky and tool-specific.

## Agent flow

If an authorized agent provisions a key, capture it directly into the vault, return an identifier/reference rather than exposing the literal value through its context, and annotate credential creation provenance. Require explicit elevated authority for credential issuance.

## Acceptance / limits

- The page may show a key only once; capture must finish or clearly fail before navigation.
- Masked/sample/public keys are not silently imported as private secrets.
- Browser origin, target site and value provenance are independently checked where possible; untrusted page markup is never an authorization grant.
- Clipboard-derived capture, if built, is explicit and narrow, not continuous collection of unrelated clipboard content.
- Never claim universal CLI capture or perfect provider detection.

## Current evidence

`CHANGELOG.md` and `docs/security.md` describe the Safari extension, save/fill and its limitations. General issuance-command capture and provider-verified metadata are design proposals.
