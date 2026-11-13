# Digital presence record

Latchkey's records under the Digital Presence Protocol (DPP 0.3.0, a proposed specification): what Latchkey is,
what its public surfaces say and on what evidence, where each surface lives, what has been checked, and what is
measured. It's the source for the site's claims; `docs/site.md` has the page rules that apply them.

## Conformance declaration

| Field | Value |
|---|---|
| Protocol | DPP 0.3.0 (CORE, PRP, DAP, DIS, AEP, OIP, OEP, MPF) |
| Entity scope | Latchkey and its planned editions; the Developer Credential Migration service; Snack Studio as publisher |
| Surface scope | The surfaces listed below |
| Observation window | None yet: nothing has been observed in production |
| Level | **Documented** for every module. The DAP checks below are **Tested** on a local preview only |
| Exclusions | Measurement (OIP, MPF) and experiments (OEP) have no data; their states are `GRAY` |
| Evaluator, evidence | The owner; this file and the receipts it names |

Nothing here claims indexing, citation, reach or any effect of a change. A check that passes locally says nothing
about how a search engine or AI system treats the site.

## Entities (PRP)

| ID | Entity | Type | Controller | Canonical source | Identifiers |
|---|---|---|---|---|---|
| `lk:latchkey` | Latchkey | Mac app and command-line tool | Snack Studio | https://latchkey.snackstud.io/ | Bundle `io.snackstud.latchkey`; Safari extension `io.snackstud.latchkey.safari`; tools `latchkey` and `lk`; repository github.com/zachshallbetter/latchkey; Homebrew cask `latchkey` in the `zachshallbetter/latchkey` tap |
| `lk:pro` | Latchkey Pro | Planned one-time in-app purchase | Snack Studio | https://latchkey.snackstud.io/pricing.html#pro | Product `io.snackstud.latchkey.pro` |
| `lk:teams` | Latchkey Teams | Proposed product, in design | Snack Studio | https://latchkey.snackstud.io/teams.html#teams | None yet |
| `lk:migration` | Developer Credential Migration | Fixed-scope service | Snack Studio | https://latchkey.snackstud.io/teams.html | None |
| `lk:snack-studio` | Snack Studio | Organization, publisher | Snack Studio | https://www.snackstud.io | latchkey@snackstud.io |

**Unresolved:** the GitHub repository's description still reads "Secrets manager for one person and their agents
(working name)" and has no homepage link. Changing it is a public edit for the owner.

## Claims (PRP, AEP)

Every claim below is published by Snack Studio itself. None has an independent reference yet, so none may be
presented as independently verified. Repeating a claim on another surface doesn't change that.

| ID | Claim | Where | Evidence | State |
|---|---|---|---|---|
| `c-free` | Latchkey is free to download and use, and the core stays free | Home, Pricing, Terms, llms.txt | Owner decision; Terms | Commitment |
| `c-notarized` | The download is notarized by Apple | Home, Pricing, Roadmap | `scripts/release.sh`; anyone can check a copy with `spctl -a -vv` | Verifiable |
| `c-storage` | Values are kept in iCloud Keychain, in Latchkey's own access group | Home, Security, API | `docs/security.md`, `Sources/LatchkeyCore` | Verifiable in source |
| `c-no-server` | No Latchkey server or account | Home, Privacy | Source; Privacy | Verifiable in source |
| `c-macos` | The app needs macOS 15 or later | Home, Teams, llms.txt, README | `App/project.yml` deployment target | Verifiable |
| `c-intel` | Intel Macs are supported | Home, Features | Built universal; not tried on an Intel Mac | `GRAY`, labelled Pending |
| `c-second-mac` | An environment restores on a second Mac | Home, Features, Security, Roadmap | Design; not tried end to end | `GRAY`, labelled pending |
| `c-license` | Source-available under FSL-1.1-ALv2 | Home (JSON-LD), Pricing, Terms | `LICENSE` | Verifiable |
| `c-proxy` | With `--proxy`, OpenAI and Anthropic keys never reach the command | Home, Features, Security | `Sources/LatchkeyCore/KeyProxy.swift`, `docs/cli.md` | Verifiable in source |
| `c-output` | Scenes show what Latchkey prints and shows, with example data | Every scene caption | `print` calls in `Sources/latchkey`, panel text in `App/Latchkey` | Verifiable in source |
| `c-pro` | Pro is planned as a $79 one-time Mac App Store purchase | Home, Pricing | Owner decision; purchase built, not on sale | Proposed price |
| `c-teams` | Teams is planned at $15 per user a month | Pricing | Owner decision | Proposed price |
| `c-migration` | Migration from $2,500 | Teams, Pricing | Owner decision | Offered |

A claim that changes is corrected on every surface that carries it (the Where column), and the correction is noted
in `CHANGELOG.md`.

## Surfaces (PRP, DAP)

| Surface | Location | Discovery | Correction route |
|---|---|---|---|
| Product site, 14 pages | latchkey.snackstud.io | Links, `sitemap.xml`, `robots.txt` | Support › Report a mistake (email or GitHub issue) |
| 404 page | `site/404.html` | Served for missing paths; `noindex`, not in the sitemap | Same |
| `llms.txt` | latchkey.snackstud.io/llms.txt | Direct reference | Same |
| Social preview | `site/og.png`, source `scripts/og-image.html` | `og:image` on every page | Same |
| Update feed | latchkey.snackstud.io/appcast.xml | Read by the app (Sparkle); not in the sitemap | Same |
| Repository and README | github.com/zachshallbetter/latchkey | Links from every footer and the docs | GitHub issues |
| Releases | github.com/zachshallbetter/latchkey/releases | Download buttons | GitHub issues |
| Homebrew tap | `zachshallbetter/latchkey` (its own repository) | Install steps | That repository's issues |
| Mac App Store listing | `packaging/app-store/listing.md` (draft, not published) | Not live | Owner |
| App Help menu | Links to Help, Privacy, Terms and security reporting | In the app | Support |

## Access checks (DAP)

Receipt, 2026-11-13: local preview (`reg serve latchkey-site`, `127.0.0.1:3200`), Chrome, 14 pages at 320, 375,
1024 and 1440 pixels in light and dark.

| Check | Result |
|---|---|
| Each page has a title, description, canonical URL, Open Graph image and one `h1` | Passed |
| JSON-LD parses; `@id`s consistent (`#latchkey`, `#website`, `#snack-studio`); breadcrumbs on every page but the home page | Passed |
| Main content is in the HTML without scripts; scenes and the app window have static fallbacks | Passed |
| Internal links and in-page anchors resolve | Passed |
| `robots.txt` allows everything and names the sitemap; no page is `noindex` except the 404 | Passed |
| Sitemap lists the 14 canonical pages with dates from Git (`scripts/sitemap.py`) | Passed |

Production states (fetchable, renderable, index-eligible, indexed, retrievable by AI systems) are `GRAY` until checked
on the published site, and indexed or cited states need Search Console, Bing Webmaster Tools or a sampled answer
panel to observe.

## Distribution ledger (DIS)

| Date | Asset | Destination | Kind | Rights | Notes |
|---|---|---|---|---|---|
| 2026-11 | Releases | GitHub Releases | Owned | FSL-1.1-ALv2 | Notarized disk images |
| 2026-11 | Cask | Homebrew tap | Owned | Same | Installs the release |

No earned, partner or paid distribution yet. None may use paid links, fake personas, undisclosed sponsorship or
automated outreach.

## Observation (OIP, MPF)

The site makes no third-party requests and runs no analytics, so nothing about visitors is collected. Each metric
below is defined but not collected; every value is `GRAY`, not zero.

| Metric | Numerator / denominator | Source | Needs |
|---|---|---|---|
| Availability (MPF-AV) | Sitemap URLs answering 200 with their canonical / sitemap URLs fetched | A dated fetch of the published site | A publish |
| Indexed coverage | Indexed pages / sitemap pages | Search Console, Bing Webmaster Tools | The owner's verification |
| Downloads | Release asset downloads per release | GitHub API (first-party, no visitor data) | Nothing |
| Referrals | Visits by source | Analytics | A privacy decision; none is planned |
| AI answers (MPF-RT is out of reach; answers are observed mentions only) | Answers that describe Latchkey correctly / queries asked | The panel below, by hand | A dated run |

### Query panel v0 (MPF-03)

Not yet run. Each run records the product and model (or "unknown"), date, answer, cited URLs and whether the
answer matches the claims above. Answers are a sample, not a census, and say nothing about which page was retrieved.

| ID | Query | Branded | Intent | Expected facts |
|---|---|---|---|---|
| q01 | What is Latchkey for Mac? | Yes | Identify | `c-storage`, `c-free`, `c-macos` |
| q02 | Is Latchkey free? | Yes | Evaluate | `c-free`, `c-pro` |
| q03 | How do I keep secrets out of .env files on a Mac? | No | Solve | references in files, values in Keychain |
| q04 | How can a coding agent use API keys without seeing them? | No | Solve | `c-proxy`, approvals and grants |
| q05 | Sync development environment variables between Macs | No | Solve | `c-storage`, `c-second-mac` (pending) |
| q06 | MCP server for secrets on macOS | No | Find | Latchkey's MCP server |
| q07 | Is Latchkey open source? | Yes | Evaluate | `c-license` (source-available, not open source) |
| q08 | Latchkey `lk run` | Yes | Use | what `lk run` does |

## Experiments (OEP)

None registered. The site changes made so far are preflight conformance, not measured effects; none is claimed to
improve discovery. An experiment needs a registered hypothesis, cohort and control, primary outcome, guardrails,
observation window, decision rule and rollback before it starts.

## Authority

Publishing the site, robots or canonical changes, Search Console and Bing verification, IndexNow submissions,
outreach, and public profile edits (the repository description) are the owner's to approve. Automated checks can
block a release; they can't approve a claim.
