# Changelog

## Unreleased

### Environments on every Mac
- Each environment has a synced record of its variables: items (shared items too) or plain settings such as
  `PORT=3000`. `latchkey run --env` reads it, so a shared item still loads when the checkout is somewhere else, as on
  another Mac. Until `latchkey env migrate` has checked an environment, the older path-based lookup still fills gaps,
  and says so.
- `latchkey env` lists, shows, sets, unsets and confirms records; `env migrate` makes them from your items and the
  files they came from. It only adds, marks what it found through file locations as unconfirmed, and reports
  conflicts, missing items, missing files and plain values that may be secret.
- Import, `set` and `mv` keep records current.
- `latchkey export PROJECT/ENV` writes an environment's env file of references. `--values` writes values in plain
  text: it asks every time naming the file, writes it owner-only and whole, refuses symbolic links, and is logged
  without the values.
- `latchkey project` matches a checkout to its project by Git remote; `project link` remembers a project's remote.
  Import names items after a linked project, so a clone under another folder name keeps its project.
- MCP: `latchkey_project` and `latchkey_export_references`, which never return values.

## 0.1.0 (unreleased)

The first release.

### App Store groundwork
- An isolated experimental sandbox build and preflight checks, following the Apple SDK patterns used in Peel.
- Persistent security-scoped file access with Settings removal, parent-folder consent for atomic env rewrites,
  and Foundation document coordination.
- A main-app privacy manifest and explicit full-functionality runtime/submission gates. No store submission
  is enabled, and the shipping direct build and Safari extension remain separate from this experiment.


### Security and reliability fixes
- **Allow Once** authorizes one read request. Implicit approval caching is removed; repeat access needs an
  explicit grant or the **No Approval** setting. Revoking a grant stops future reads through it immediately,
  without recalling values already released or overriding other grants and No Approval settings.
- Proxy mode refuses custom provider base URLs, plaintext supported keys, and additional variable or file
  deliveries of a protected key. It refuses runs without a supported key reference and never follows upstream
  redirects. Other credentials are delivered normally.
- Quoted multiline `.env` values are imported and rewritten in full. Malformed files are refused before saving;
  a rewrite stops if the file changed during approval. File permissions are preserved.
- Temporary key files have distinct paths per full item ID, preventing collisions between environments.
- Command-line redaction covers URL credentials and common secret query parameters. Arbitrary arguments still
  need care: redaction is heuristic.
- Safari discards stale detections after changes, removal or navigation, bounds retained candidates, and rechecks
  values before saving. Password and hidden fields are excluded from focus and input handlers.
- App, website and guides describe effective access, proxy limits, unverified sync delivery, and preview-only
  installation. Regression coverage includes authorization, imports, file delivery, proxy configuration and
  Safari capture lifecycle.


### Storage and sync
- Values in iCloud Keychain, in Latchkey's own access group, synced to every Mac signed in to your Apple Account.
- Kind, agent-safe, service, note and "used in" travel with each item.
- Settings › **Move to iCloud Keychain** for items saved by an unsigned build.

### Running commands
- `latchkey run` fills in `latchkey://` references and hides values in the command's output.
- `--env PROJECT/ENV` runs without an env file; `--file NAME=ID` and `latchkey-file://` deliver values as temporary
  files.
- Documented exit codes; refusals and missing items say what to do.
- The command-line tool starts the app when it isn't running.

### Agents
- Grants can end when the agent quits (`--session`), cover only one command (`--command`), or one use (`--once`);
  the approval panel offers "until claude quits" and "Only for this command".
- `latchkey run --proxy`: OpenAI and Anthropic keys never reach the command; it gets a placeholder and a local base
  URL, and the real key goes only to the provider.
- `latchkey run --aws-session` / `--aws-role`: short-lived AWS credentials from STS instead of the long-lived key.
- `latchkey touched` and `latchkey rotate`: see what a session was given, and replace it, with history kept and
  linked environments pushed.
- Use Latchkey from another Mac over SSH (`LATCHKEY_SOCKET`); each read without No Approval asks; local grants do not apply.
- `latchkey mcp`: an MCP server with status, list, check, run and request-grant tools. It exposes no direct secret-read tool;
  output is masked and capped, but transformed secrets can still leak, and grants an agent asks for are limited to its folder, a day, and non-production
  environments.
- `latchkey check` shows what a run would get without asking, what would ask, and what's missing.

### Security
- Approvals and grants judge the caller by what the kernel reports: its real working folder and command line, and
  whether it's Latchkey's signed command-line tool. Other programs are named by their path, with a warning.
- Grants live in a keychain item only Latchkey can change, not in a file.
- The command-line tool checks the app's signature before sending anything.
- Development installs no longer carry the debugging entitlement.
- The access log is chained with HMAC; `latchkey log --verify` finds changed, removed or added entries. Likely
  secrets in command lines are redacted.
- Approving "Allow from this folder" from a caller whose folder is `/` no longer grants every folder.

### Approvals and grants
- An approval panel with the program chain, folder and command, then Touch ID, Apple Watch or your password.
- Grants for a folder, its subfolders and its repository's worktrees, for up to 7 days; for items, environments or
  projects.
- Agent-safe items for values that aren't secret.

### Organizing
- Items belong to a project's environment (`project/environment/NAME`) or are shared.
- A tree of projects and environments, with counts, environment badges, and where each environment lives.
- Services detected on import; editable.
- Multi-select and project-wide actions, each with one approval.
- Move items between projects and environments, with references updated in their files.

### Importing
- `latchkey import --scan ~/Projects` finds and imports every project's env files at once.
- `latchkey import` for one file or many (`--batch`), with one approval, `--rewrite`, `--share-identical`,
  `--agent-safe-pattern`, and expiring Vercel and Turbo tokens skipped by default.
- Projects named after the repository's main checkout; environments from the file name.

### History
- The last 10 values of each item, with show and restore.
- Recently Deleted for 30 days.

### Remote locations
- Link environments to Vercel, GitHub Actions, Railway and Fly; compare names; push with approval every time and an
  extra confirmation for production. Nothing is deployed.

### The app
- Window with sidebar, tree, detail and bulk actions; menu bar panel; settings; open at login.
- A light and dark app icon.
- One copy runs at a time.

### Safari
- Latchkey for Safari spots keys on any page you allow it on: about twenty provider formats, private keys, database
  URLs with a password, and labelled random secrets, skipping masked values, examples, publishable keys and
  certificates. Confident finds get a Save to Latchkey button beside the key; others are listed in the toolbar panel,
  with a count on its button. Save Selection to Latchkey saves anything it missed. It can't read stored values.
- After a save, the extension shows the reference to use; its toolbar button says whether it can reach Latchkey.
- The Save to Latchkey button sits beside the copy of a key you can see, not a hidden copy kept for the page's copy
  button, and Save says so when it can't reach the app instead of waiting.
- The Save to Latchkey button is placed from the box holding the key (inside a one-line field, or on a larger box's
  top edge) and appears once it has settled; the panel opens beside the box, not over the key.
- Fields that expect a key, token, secret, private key, certificate or connection string are recognized by label and
  attributes and listed in the toolbar panel.
- Fill from Latchkey: a badge in a recognized field lists the items allowed on that site; choose one and approve with
  Touch ID to fill it. Items fill only on their service's own site and on deployment platforms, over https, in the
  page itself (not frames), with approval every time.
- Per-item fill sites: **Fill in Safari on** in an item's details, or `latchkey update --fill-sites`, limits an item to
  the sites you list, in place of the default. The extension can't change it. Certificates are offered as public items.
- When a page says it shows a new key only once, the save panel opens from its button without a click; saving still takes
  your press and Touch ID.

### Approvals
- With Touch ID, the approval panel takes the fingerprint itself: one step, not a panel and then a sheet.
- Things you start yourself, in the window or in Safari, ask for Touch ID alone.
- After an import or a new item, Latchkey shows the reference and the `lk run` command to use next.

### Distribution (release tooling; no public release yet)
- Developer ID-signed and notarized, in a disk image, with the command-line tool inside the app
  (**Latchkey › Install Command Line Tool…**, which also adds `lk`).
- A Homebrew cask, written by the release script.
