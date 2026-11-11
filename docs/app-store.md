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
| External CLI / MCP connection | Authenticated local transport; Security audit-token code identity | Redesign and signed end-to-end proof required |
| Network / service APIs | Foundation `URLSession`; Network framework where a listener is needed | Existing proxy/STS code; native remote push redesign still required |
| Login/background service | ServiceManagement `SMAppService`, with explicit user consent | Current login setting exists; a broker service design needs separate validation |
| Optional paid features | StoreKit only if pricing later requires it | No purchase flow is being added or assumed |

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
The built-bundle preflight currently reports the Safari bundle's missing privacy manifest, which belongs to the
extension integration. Every full-functionality gate in readiness.json remains pending.

## Full-functionality blockers and acceptance tests

| Area | Required redesign / proof before submission |
| --- | --- |
| Broker location and CLI discovery | A stable endpoint in an allowed container, with no assumption that `NSHomeDirectory()` is the user's real home. An old direct build and the store build must not silently answer different sockets for the same vault. |
| Caller identity and grants | Measure what a signed sandbox process can inspect. If context is supplied by the signed CLI, bind it to its kernel-authenticated connection and process identity. Never trust caller-supplied folder/command fields from arbitrary clients. Unknown context must not qualify for a grant. Test forgery, replay, PID reuse and SSH forwarding. |
| Command execution and MCP | Prove the real terminal/agent entry point can run Node/npm, shells and representative developer tools with only the intended keys and file permissions. Preserve signals, exit codes, masking, temporary files, proxy isolation and short-lived AWS credentials. An inherited helper is not evidence of unrestricted execution. |
| Remote pushes | Current `ProcessRunner` discovers Homebrew/mise tools and their sign-ins outside the app container. Plan native provider APIs and authentication, or establish a reviewable supported boundary; do not secretly delegate around the sandbox. Test all four providers and production confirmation. |
| File access | In a signed sandbox build, read an explicitly selected env file, grant its parent, rewrite it, restart, restore permissions, move references, disconnect/reconnect a volume, and remove permission. Verify an unselected folder remains inaccessible. |
| Migration and sync | Preserve item identity and access groups; handle the old Application Support log and preferences, old login-keychain items and history without silently falling back to a second empty vault. Test both directions on a separate Mac. |
| Safari | The extension owner integrates and validates its signing, App Group transport, resource membership and privacy manifest with the chosen final store target. Do not copy the direct app's entitlements into the extension. |
| Clean-machine review | Full flow on a clean Mac via Apple Distribution/TestFlight, no development entitlements or pre-existing file grants, usable without Touch ID hardware, no hidden prerequisites or unsupported installer. |

## Privacy, export compliance and listing

The draft state lives in `packaging/app-store/readiness.json`. Support/privacy URLs, review contact confirmation,
export classification, screenshots and reviewer steps remain to be completed. There is no upload command in this
preparation tooling.

The privacy inventory is specific to Latchkey:

- `CA92.1`: the app's own preferences and local bookmark records.
- `C617.1`: metadata for files within the app's own storage.
- `3B52.1`: metadata of user-selected files being rewritten, including their permissions.
- No disk-space, keyboard or boot-time reason is copied from Peel. Apple's current required-reason article names
  mobile platforms; keep the macOS inventory truthful without assuming every mobile upload rule applies unchanged.
- No telemetry, ads or developer-operated data backend is present. Explain iCloud Keychain and user-requested
  provider traffic in the public privacy policy. Confirm the final data-flow inventory before publishing privacy
  labels; the Safari bundle has its own inventory and owner.
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
