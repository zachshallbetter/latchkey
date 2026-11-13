# Mac App Store preparation

The target is **full Latchkey functionality** in a properly sandboxed app. There is no approved reduced-feature
store edition, and the sandbox experiment is not a release candidate. The direct build remains the production
implementation while the boundaries below are redesigned and proved.

## Reference and Apple SDK choices

Peel is the local implementation reference: its `app/Peel/FolderAccess.swift`, separate store target and helper
entitlements, static preflight, signed-bundle verification, and sandbox self-test. Its release/account actions and
feature exclusions are not instructions for Latchkey. Do not reuse Peel's bundle IDs, product IDs, credentials,
export-compliance answer, or claims that its tests passed as evidence about Latchkey.

| Boundary | Apple SDK / implementation | Current status |
| --- | --- | --- |
| Vault, versions, grants | Security framework, existing Keychain access group | Existing implementation; signed sandbox round trip and migration still need proof |
| User authorization | LocalAuthentication and LocalAuthenticationEmbeddedUI | Existing implementation; signed sandbox interaction still needs proof |
| Selected files and project folders | AppKit `NSOpenPanel`; Foundation security-scoped bookmarks | Store experiment implemented, with balanced scope ownership and local persistence |
| Coordinated replacement of env files | Foundation `NSFileCoordinator`, then checked atomic replacement | Implemented; changed-file and permission checks remain in force |
| Internal helper work | Evaluate an embedded `NSXPCConnection` service or sandbox-inheriting helper | Not implemented; a helper must retain the parent's restrictions, not escape them |
| External CLI / MCP connection | App Group UNIX socket; Security audit-token dynamic code identity | Signed terminal CLI probes pass; packaging, MCP and full acceptance remain pending |
| Network / service APIs | Foundation `URLSession`; Network framework where a listener is needed | Existing proxy/STS code; remote pushes now call the services' APIs (see Remote pushes below) |
| Login/background service | ServiceManagement `SMAppService`, with explicit user consent | Current login setting exists; a broker service design needs separate validation |
| Optional paid features | StoreKit 2: `Transaction.currentEntitlements`, `Transaction.updates`, `AppStore.sync()` | Implemented for Latchkey Pro (see Latchkey Pro purchase); real purchases need App Store Connect |

## What this slice implements

- `App/project.appstore.yml` overlays the current project with a sandboxed experimental configuration. It preserves
  the app's existing vault identity and Safari dependency. No shipping target or Safari source is changed.
- `App/AppStore/Latchkey.entitlements` names the experiment's exact permissions: selected-file read/write,
  app-scoped bookmarks, local listener and outbound network access, the existing App Group and Keychain groups.
  No temporary exception, unrestricted home-folder entitlement, Apple Events or sandbox escape is added.
- `SecurityScopedAccess` retains the **original** scoped URL, refreshes stale bookmarks, keeps unavailable volumes
  remembered, deduplicates repeated selections, and stops the corresponding scope when access is removed.
- Store-only Settings lists file permissions. These are independent of broker grants: choosing a folder never
  approves release of a secret. Removing a file permission does not revoke secrets already released to a process.
- Atomic env replacement requests the parent directory when only the file itself was selected. Cancelling that
  request stops the import or move before vault changes. The direct build's file-access flow is unchanged.
- The app privacy manifest describes the current no-tracking/no-developer-collection implementation and the
  app's defaults and file-metadata APIs. It is an API inventory, not the App Store privacy questionnaire.

The standard CLI installer is not run by the sandbox experiment: writing links under `~/.local/bin` from the
store app is not an approved distribution design. This is a visible experiment limitation, not a decision to
remove CLI functionality from the eventual store product.

## Latchkey Pro purchase

Latchkey Pro is one non-consumable in-app purchase, `io.snackstud.latchkey.pro`, in this build only. The direct
build compiles no purchase code (`LATCHKEY_APP_STORE`) and its Settings shows a link to the App Store version.

- `ProEntitlement` (`App/Latchkey/ProEntitlement.swift`) is the one resolver: `Transaction.currentEntitlements`,
  accepting only `.verified` transactions for the product that aren't revoked. A `Transaction.updates` listener
  picks up refunds and purchases made elsewhere. A failed or unverified lookup means not Pro and never throws into a
  caller. Nothing about the purchase is stored by Latchkey.
- The broker enforces Pro in one place, `Broker.handle`, through `ProGate.features` (op name to feature name) and its
  injected `hasPro` check, which the app wires to `ProEntitlement`. `ProGate.features` is empty: duplicates, combine
  and everything else shipped stays free, and storing, reading, approving, granting, running, importing, exporting,
  deleting, history and restore can never be gated (`ProGateTests`). A gated op without Pro returns `ok: false` with
  an error naming Latchkey Pro and the feature; the app shows the Upgrade sheet.
- Settings › Latchkey Pro: status, Buy (price from `Product.displayPrice`), Restore Purchases, purchase date.
- `App/AppStore/Latchkey.storekit` holds the product (USD 79.99) for local testing; the overlay's `Latchkey` scheme
  runs with it. In Xcode, run the store scheme and use Debug > StoreKit > Manage Transactions.

Not verified without App Store Connect: a real purchase, Restore Purchases against a real account, refunds and
Family Sharing (off). Create the product, price and review screenshot there before submission.

## Build and inspect without changing the installed app

```bash
python3 scripts/appstore-preflight.py
python3 -B -m unittest discover -s scripts/tests -p 'test_appstore_*.py'
python3 scripts/build-appstore-sandbox.py --output /private/tmp/latchkey-sandbox-build-1
```

Choose a new output directory each time. The builder snapshots App, Sources, Tests and Package.swift, then runs
XcodeGen and Xcode against that snapshot. It never deletes a previous build, generates plists in the working
checkout, installs an app, changes Safari registration, or uploads to Apple. Its default unsigned build proves
compilation only: a binary compiled with sandbox settings but not signed is not evidence of sandbox behavior.

`--signed` uses existing development signing. It does not pass `-allowProvisioningUpdates` or create Apple-account
resources. A signed run and a later Apple Distribution/TestFlight run are separate evidence requirements.

```bash
python3 scripts/appstore-preflight.py --app /path/to/Latchkey.app --dev
python3 scripts/appstore-preflight.py --submission --app /path/to/distribution/Latchkey.app
```

Signed-bundle inspection uses Security.framework to decode the OS entitlement dictionary and validate nested
code, signing teams and distribution certificates; it does not parse `codesign`’s display or legacy XML format.
The first bundle check may report integration gaps owned by the Safari work. Submission checks deliberately fail
until `packaging/app-store/readiness.json` records all runtime gates, owner-reviewed metadata and a release
artifact. Static checks and evidence-file existence are not substitutes for reviewing those test results.

## Native sandbox probes

After building with existing development signing, run:

```bash
python3 scripts/test-appstore-sandbox.py --app /path/to/Debug/Latchkey.app --report /private/tmp/latchkey-sandbox-report.json
```

The Debug-only `--sandbox-self-test` entry runs before the normal app model, single-instance handling, Keychain,
production broker or Safari connection exists. It uses temporary fixtures to check container env replacement,
refusal of an unselected home-file write, App Group local IPC with kernel-bound signature checking, and launching
a system child. It reports whether parent-process metadata is visible as booleans, without recording arguments.
It never opens a window or changes the installed app's registration. The builder uses the existing build register
when available to avoid colliding with other local builds.

The probe refuses an unsigned build. A successful component report explicitly says `submissionReady: false`:
it does not prove external CLI context, npm execution, user-selected folder access, providers or sync. Those need
the acceptance tests below, followed by an Apple Distribution/TestFlight run.

## Recorded component result

On 2026-11-11 the development-signed Debug experiment passed all four headless component probes. Parent-process
arguments and working-directory visibility were both available in that run; external caller validation still
needs its own test. The first IPC fixture exceeded the UNIX socket path-length limit; its short, unique socket
name fixed the fixture. Preserve that limit in the final transport design.

[The recorded report](evidence/app-store/2026-11-11-component-probes.json) lists what was and was not tested.
The built-bundle preflight passes for the Safari bundle's privacy manifest.

On 2026-11-13 three more fixture-only probes ran against a development-signed Debug build (new commands below).
Only `vaultAndHistory` is recorded as passed; the other two probes passed but leave their gates pending.

| Probe | Result | Evidence |
| --- | --- | --- |
| Vault and history | Passed: save, read, change with version, delete, restore and cleanup in the app's access group under a unique non-synchronizing fixture service; an unentitled access group is refused. | [report](evidence/app-store/2026-11-13-vault-history.json) |
| File access and revocation | Passed, but needs a manual step: see below. | [report](evidence/app-store/2026-11-13-file-access.json) |
| CLI adversarial cases | Passed 18 of 18 (14 transport plus 4 new); PID reuse, MCP and SSH remain. | [report](evidence/app-store/2026-11-13-cli-adversarial.json) |

```bash
python3 scripts/test-appstore-vault.py --app /path/to/Debug/Latchkey.app --report /private/tmp/latchkey-vault-report.json
python3 scripts/test-appstore-files.py --app /path/to/Debug/Latchkey.app --report /private/tmp/latchkey-files-report.json
```

The vault probe never queries the real `latchkey` or `latchkey.history` services and never synchronizes. It does not
cover real items, iCloud sync, migration or the approval UI. The history store keeps dates to one-second resolution,
so two versions saved in the same second tie for "latest"; the probe waits between them. Existing behavior, not changed.

The file probe runs three launches (grant, relaunch, revoked). An unsandboxed harness issues App Sandbox extension
tokens for fixture paths, the mechanism the Open panel uses, and `SecurityScopedAccess` takes it from there. A
headless run cannot click NSOpenPanel, and a sandboxed process cannot create a security-scoped bookmark for a
path it was never granted. Proven: an unselected file is unreadable; the selected file is readable; atomic rewrite
fails with only the file granted and succeeds, keeping permissions, once its parent is granted; the saved records
restore access in a new process; after removal the file stays unreadable in the next launch, and an unselected
sibling folder is denied throughout. After removal in the same process the file was already unreadable, but the
Open panel's own extension may behave differently, so only the next-launch result is relied on.

Manual test (Debug sandbox build, a scratch folder with a `.env` file, no real secrets):

1. Settings, File permissions: choose the `.env` file. Expect it listed, and Import to read it.
2. Move or import so Latchkey rewrites the file. Expect the Allow prompt for its folder; Cancel must leave the
   file and vault unchanged, Allow must rewrite it with the same permissions (`ls -l`).
3. Quit and reopen. Expect the file permissions still listed and a second rewrite to work without a prompt.
4. Disconnect the volume (or a disk image) holding the file, reopen, reconnect. Expect it remembered and usable again.
5. Move the file's folder in Finder and rewrite. Expect a stale bookmark to refresh or a clear request to choose again.
6. Remove the permission in Settings, quit and reopen. Expect the file to be inaccessible and a sibling folder never prompted.

Gates after this run: `vaultAndHistory` passed (development signing only; TestFlight and migration belong to their own
gates). `signedFileAccessAndRevocation` and `authenticatedCLITransportAndCallerIdentity` remain pending.

## Terminal execution and broker transport

The sandboxed app serves credentials; a separately signed terminal CLI executes developer commands in its existing
terminal context. This is an explicit two-product integration under evaluation, not a sandbox escape or proof that
an unrestricted CLI can be embedded in the store bundle. The store app does not install, download or launch an
unsandboxed helper. Both the direct download and App Store preparation remain supported distribution paths.
Final CLI distribution and App Review acceptance remain release gates; an App Store user must not be promised
full functionality until that boundary has been reviewed and the complete workflow verified.

The experiment listens on `cli.sock` in its App Group and requires the CLI's exact signing identifier and the same
Apple-issued signing team. It does not open the old private-container socket as a fallback. The Safari listener
retains its separate identity and operation restrictions. The CLI authenticates the app before writing any request
bytes. `LATCHKEY_BROKER=auto|direct|app-store` selects a channel; automatic store selection verifies the installed
app's signature before trusting its distribution metadata. `LATCHKEY_LOCAL_SOCKET` overrides only the local path,
with authentication retained. It cannot be combined with the explicit SSH-forwarding `LATCHKEY_SOCKET` setting.
Store forwarding is deliberately unavailable until an authenticated forwarding boundary is designed; the direct
broker's existing SSH behavior is preserved.

Security.framework must use `kSecGuestAttributeDynamicCode` with the kernel's audit token. Its default disk-based
peer lookup fails with EPERM when the sandbox cannot read an external terminal CLI executable. The dynamic
representation fixes that access requirement without replacing signature validation with a claimed path or PID.
Caller cwd, argv and ancestry still come from kernel APIs. Process start times bracket PID-based context reads;
unavailable or unstable context cannot qualify for a grant. No new caller-supplied context fields are trusted.
`latchkey log` now requests entries from the selected broker instead of reading the CLI's local Application Support
path, which would show the wrong log for the sandbox container or an SSH-forwarded broker. Entry limits are bounded.
The run-command parser recognizes AWS option values and `--env-file=...`; unknown options cannot masquerade as a
command for a restricted grant.

Run the fixture suite against an already development-signed Debug app and independently signed same-team CLI:

```bash
python3 scripts/test-appstore-cli.py --app /path/to/Latchkey.app --cli /path/to/signed/latchkey --report /private/tmp/latchkey-cli-report.json
```

The script requires installed Node/npm, uses a random App Group socket and in-memory store, never opens the real
vault, and cleans up the fixture broker. It tests mutual authentication, refusal of unsigned callers, zero request
bytes to an impostor server, shell/Node/npm execution, masking on both streams, exit status, key-file cleanup,
command/folder grant matching, revocation and SIGTERM forwarding. On 2026-11-11 all 14 signed transport probes passed. The recorded
[transport report](evidence/app-store/2026-11-11-cli-transport.json) is component evidence; it does not clear the
full CLI/identity or execution/proxy/AWS gates.

On 2026-11-13 four fixture-only adversarial cases were added and all 18 passed
([report](evidence/app-store/2026-11-13-cli-adversarial.json)): forged `grant`, `get` and `check` fields from an
unsigned process are refused and create no grant; a signed CLI's claimed `--folder` and `LATCHKEY_ORIGIN` cannot create
or widen a grant (only the approver can); a single-use grant cannot be replayed; and a caller that disconnects after
sending leaves the broker serving. Authentication is bound to the connection, not to message bytes, so replay is
exercised as a consumed grant and an unsigned resend, not a captured signed request. Still pending: real PID reuse of
a signed caller (wrap-around, or a broker that delays context reads; the start-time bracket is covered only by unit
tests), the MCP entry point, ancestor-bound session grants, SSH forwarding, live proxy and STS, real approval UI and
vault, packaging and TestFlight.

## Full-functionality blockers and acceptance tests

| Area | Required redesign / proof before submission |
| --- | --- |
| Broker location and CLI discovery | Dedicated App Group endpoint and explicit channel selection implemented. Verify registered-app discovery, long home paths, stale endpoints, direct/store transitions and final CLI distribution on a clean Mac. |
| Caller identity and grants | Measure what a signed sandbox process can inspect. If context is supplied by the signed CLI, bind it to its kernel-authenticated connection and process identity. Never trust caller-supplied folder/command fields from arbitrary clients. Unknown context must not qualify for a grant. Test forgery, replay, PID reuse and SSH forwarding. |
| Command execution and MCP | Prove the real terminal/agent entry point can run Node/npm, shells and representative developer tools with only the intended keys and file permissions. Preserve signals, exit codes, masking, temporary files, proxy isolation and short-lived AWS credentials. An inherited helper is not evidence of unrestricted execution. |
| Remote pushes | **Native, implemented; not yet verified against the real services.** The store build never runs a tool (`Broker(nativeOnly: true)` with an `UnavailableRunner`): each link names a shared item that holds the service's access token, and the broker pushes with `URLSession` to `api.vercel.com`, `api.github.com`, `backboard.railway.com` and `api.machines.dev` only. Vercel (env upsert), GitHub Actions (repository and environment secrets, sealed-box encrypted in Swift and checked against libsodium vectors), Railway (`variableUpsert`) and Fly (Machines API secrets) are all native; nothing is unsupported. Not native: Vercel and Railway links that rely on a linked folder (`dir`) have no project to name, so they need `project` set; Railway project tokens aren't accepted. Production confirmation, per-push approval and the approval naming the token item are unchanged and unit-tested. To pass this gate: with a real throwaway project at each service, link with a token item, push to a non-production target, confirm the values arrive and nothing deploys, repeat the push (upsert), revoke the token and see the typed error, and push to a production-named target from the signed sandbox build; record the evidence. Details: [remote.md](remote.md#pushing-through-an-api). |
| File access | In a signed sandbox build, read an explicitly selected env file, grant its parent, rewrite it, restart, restore permissions, move references, disconnect/reconnect a volume, and remove permission. Verify an unselected folder remains inaccessible. |
| Migration and sync | Preserve item identity and access groups; handle the old Application Support log and preferences, old login-keychain items and history without silently falling back to a second empty vault. Test both directions on a separate Mac. |
| Safari | Source side done: the extension has its own privacy manifest (`App/Privacy/Safari/PrivacyInfo.xcprivacy`: no tracking, no collected data, no required-reason API) in its resources, and its overlay entitlements are the sandbox plus the App Group only. Still to prove on a signed build: App Group transport to the sandboxed app, enabling it in Safari, and an end-to-end save and fill. Do not copy the direct app's entitlements into the extension. |
| Clean-machine review | Full flow on a clean Mac via Apple Distribution/TestFlight, no development entitlements or pre-existing file grants, usable without Touch ID hardware, no hidden prerequisites or unsupported installer. |

## Privacy, export compliance and listing

The draft state lives in `packaging/app-store/readiness.json`. The support, privacy and marketing URLs are recorded
(the app's Help menu links the first two and the terms); review contact confirmation, export classification and
screenshots remain to be completed. Listing text drafts (name, subtitle, promotional text, description, keywords,
what's new and reviewer notes) are in `packaging/app-store/listing.md`. There is no upload command in this
preparation tooling.

The privacy inventory is specific to Latchkey:

- `CA92.1`: the app's own preferences and local bookmark records.
- `C617.1`: metadata for files within the app's own storage.
- `3B52.1`: metadata of user-selected files being rewritten, including their permissions.
- No disk-space, keyboard or boot-time reason is copied from Peel. Apple's current required-reason article names
  mobile platforms; keep the macOS inventory truthful without assuming every mobile upload rule applies unchanged.
- No telemetry, ads or developer-operated data backend is present. Explain iCloud Keychain and user-requested
  provider traffic in the public privacy policy. Confirm the final data-flow inventory before publishing privacy
  labels. The Safari bundle's inventory is empty: it only relays messages to the app over the App Group socket.
- Review encryption export compliance for **this** app, including Security/CryptoKit, STS signing and networking.
  Peel's owner-approved answer does not establish Latchkey's classification. The experiment does not set
  `ITSAppUsesNonExemptEncryption` prematurely.

## Official references

- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- [App Review Guidelines, especially 2.4.5 and 5.1.1](https://developer.apple.com/app-store/review/guidelines/)
- [Privacy manifests](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
