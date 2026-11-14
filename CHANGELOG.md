# Changelog

## Unreleased

### Mac App Store
- The App Store version is free in its first release: Pro isn't on sale until it has features of its own, so the store
  build makes no StoreKit calls and shows no Membership section.
- The App Store version links to the command-line tool instead of installing it, and the release now ships the tool
  on its own: `latchkey-cli-VERSION.zip`, notarized, and a Homebrew formula (`brew install latchkey-cli` from the
  tap). The tool claims the app's App Group so it can reach the store app.
- Quitting the App Store version from the Dock quits it unless you choose otherwise in Settings.
- The store build declares its encryption for export compliance, drops the unneeded network-server entitlement and
  the old development keychain group, and reports itself as the `app-store` channel. The Safari extension's version
  now matches the app's, and releases check it.
- `scripts/release-appstore.py` builds the App Store package; the listing, reviewer notes, privacy, age rating and
  export answers, and six screenshots are in `packaging/app-store/`.

### In-app settings
- Settings now lives in the main window, with General, Privacy & Approval, Storage & File Access, Developer Tools,
  Membership, and About & Updates sections. Sidebar, menu bar, Command-comma and upgrade actions share it.
- Appearance, clipboard and reveal timers, hiding values when Latchkey loses focus, and Dock quit behaviour are
  saved on this Mac. Copying an environment names the chosen clear time in its approval; `lk export --clipboard`
  keeps 60 seconds. A value approved while Latchkey isn't in front is hidden with a notice. Authorization is
  unchanged.
- Membership shows verified one-time App Store ownership and the App Store price, with Buy, Restore Purchases,
  availability checks and purchase support links.

### App
- The sidebar shows each service's site icon, bundled with the app, and a project's own favicon or app icon when
  its checkout has one; otherwise the initial or a folder, as before. Nothing is fetched.

### Security
- An approval now names every change to who may read an item without asking, or to whether it's treated as a secret:
  `set` (including one with no value) and `import --replace` say "let agents read ... without approval" or "make it
  a plain value", as `update` already did. The approval panel shows the request's wording too, not just the verb.
- Restoring an earlier version of an item that still exists changes only its value. It no longer re-applies that
  version's agent-safe, kind, service or Safari fill sites, so a restore can't quietly undo a later tightening.
  Bringing back a deleted agent-safe item says so in the approval.
- The MCP tool `latchkey_export_references` writes only inside its `cwd` (symlinked folders are followed before the
  check) and is marked destructive, since it can replace a file there without asking.
- Latchkey for Safari no longer offers fills on sites a platform hosts for its customers. The default fill sites are
  each service's own key page host and the platforms' dashboards (app.netlify.com, dashboard.render.com,
  dashboard.heroku.com, railway.com), not every subdomain of railway.app, google.com or amazon.com.

## 0.3.0 (2026-11-13)

### Latchkey Pro
- Mac App Store version: Latchkey Pro as a one-time in-app purchase (`io.snackstud.latchkey.pro`), checked with
  StoreKit 2 (Apple-signed, verified on the Mac, works offline, drops on refund). Settings › Latchkey Pro shows the
  status, **Buy** with the App Store price, **Restore Purchases** and the purchase date. The direct download has no
  purchase code and links to the App Store version.
- The broker refuses Pro operations without Pro, naming Latchkey Pro and the feature, and the app shows an Upgrade
  sheet. No Pro operations exist yet: everything shipped so far, including duplicates and combine, stays free, and
  storing, reading, approving, running, importing, exporting, deleting and restoring can never require Pro.

### Remote pushes
- Remote locations can push through each service's HTTPS API with an access token kept as an ordinary item:
  `latchkey remote link ... token=ITEM` (and, for a Vercel team project, `team=`). Vercel environment variables,
  GitHub Actions repository and environment secrets (sealed-box encrypted), Railway variables and Fly secrets are all
  supported, and `remote status` works the same way. The direct download still uses `vercel`, `gh`, `railway` and
  `flyctl` for links without a token item; the Mac App Store build, which can't run them, uses the API only.
- The push approval names the token item. The token goes only to the service's own API host and is never returned,
  logged or quoted in an error; requests time out, responses are size-capped and checked, redirects aren't followed,
  and the only retries are for a rate limit or 502/503/504.
- Link records gain optional `tokenItem` and `team` fields; links saved before them decode unchanged.

### Website
- Privacy policy, terms and support pages, linked from every footer; canonical URLs and a sitemap for
  latchkey.snackstud.io, published from Vercel on request only.
- Pricing: Latchkey Pro is a one-time in-app purchase ($79) in the Mac App Store version, with updates included and
  no subscription; the direct download stays free. Early-access, migration and design-partner requests go to
  latchkey@snackstud.io.

### Project
- Source-available under the Functional Source License (FSL-1.1-ALv2); security reports can also go to
  latchkey@snackstud.io.
- The repository is public. Releases download from GitHub, and a Homebrew tap installs them
  (`brew tap zachshallbetter/latchkey`, `brew trust zachshallbetter/latchkey`, `brew install --cask latchkey`).

### Security
- `latchkey run --proxy` serves a request only when its connection comes from the command or a process it started,
  found in the kernel's socket table with process start times so a reused process ID can't qualify. A program that
  reads the placeholder from the command's environment is refused. The proxy stops, and closes open connections,
  when the command exits.
- New `--proxy-models A,B` and `--proxy-requests N` limit the models a run may name and how many requests it may
  make; `latchkey run` says on standard error that they are enforced. The MCP `latchkey_run` tool takes
  `proxy_models` and `proxy_requests`.

### Import
- Import classes each line as a secret, a setting, a public value or an existing reference, and shows the class in
  `lk import --dry-run` and in the app's import sheet, where you can change a line's class before saving. Settings
  (`PORT`, `NODE_ENV`, `LOG_LEVEL`, true/false flags) are left in the file; public values (`NEXT_PUBLIC_*`, `VITE_*`,
  publishable keys, web addresses without credentials) are saved as plain values; anything unclear is a secret.
  `--class KEY=secret|setting|public` changes a line from the command line.

### CLI
- `lk scan [DIR]` finds env files that still hold plain values: ones equal to a stored item (compared inside Latchkey;
  only item names come back, and it asks every time) and ones that look secret. It prints file, line and the item,
  never a value, and exits 1 when it finds any. `--staged` scans only what a commit would add, and
  `lk scan --install-hook` writes a pre-commit hook that refuses such commits.

### Export
- `lk export PROJECT/ENV --out FILE --merge` updates the variables Latchkey manages in an existing env file, appends
  the missing ones and keeps every other byte (comments, order, other variables, line endings). It lists the names it
  adds and updates first and asks to go ahead, unless `--yes`.
- **Export Environment…** in the app writes an env file of references or values, with the same checks as the command
  and the same merge.
- `lk export PROJECT/ENV --values --clipboard` and **Copy Environment as .env…** copy an environment as an env block
  for dashboards that take a pasted one. Each copy asks, naming the environment and the clipboard; it stays on this
  Mac, is hidden from clipboard managers and clears after 60 seconds. Agents and Safari can't copy. The log says
  "copied to the clipboard".

### App
- The direct download updates itself with Sparkle: **Latchkey › Check for Updates…**, and **Check for updates
  automatically** in Settings. It reads https://latchkey.snackstud.io/appcast.xml and sends no system profile. The
  App Store build has no updater. `scripts/release.sh` signs the disk image and writes `site/appcast.xml` when
  Sparkle's `sign_update` and key are available.
- **Help** menu: Latchkey Help, Privacy Policy, Terms of Use and Report a Security Issue.
- App Store build: Latchkey for Safari carries its own privacy manifest (no tracking, no data collected, no
  required-reason API), and `packaging/app-store/listing.md` drafts the store listing.

## 0.2.1 (2026-11-12)

### Website
- The home page shows Latchkey in use: self-playing scenes of a fresh clone rebuilt with `lk project` and
  `lk export`, an env file imported, a second Mac (marked pending until tried), an agent being granted a folder and
  asked again for production, and rotation. The approval demo follows the one-prompt panel.
- Leads with "Your projects move. Your secrets don't." New Features, Security, Pricing, For teams and Roadmap pages;
  every page shares a header (Features, How it works, Pricing, Security, Docs) and one footer, and works on phones
  and in light mode.

### App
- Closing the window or Quit from the Dock leaves Latchkey in the menu bar, without a Dock icon; Quit there (or in
  the app menu) quits it.

### Fixes
- The release checksum file names the disk image alone, so `shasum -a 256 -c` works next to a downloaded copy.

## 0.2.0 (2026-11-11)

### Duplicates
- `lk duplicates` and **Review › Find Duplicates…** find items holding the same key, with one approval, and say what
  to do: give production its own key, keep one item where an environment has several names for a value, combine the
  rest into one shared item (suggested names never collide), or mark identifiers as plain values. The approval says
  it's comparing values. Values never leave Latchkey, and agents can't ask.
- `lk combine IDS --into NAME` and **Combine into Shared…** make them one shared item; environments and the files they
  were imported from follow, and the originals go to Recently Deleted.

### Remote locations
- **Add Remote Location** is its own sheet: pick the service, fill in its details (each explained), choose the
  environment, and see whether the service's tool is installed, with a link to install it. **Add Location** stays
  disabled until the details are complete.

### The window
- An **Item** menu acts on every selected row, with shortcuts: copy value (⌥⌘C), copy references (⇧⌘C), copy as
  env file lines (⇧⌘E), require approval or let agents read (⌥⌘A), move (⇧⌘M), grant access (⇧⌘G) and delete
  (⌘⌫ or Delete). The shortcuts work while the list has focus; the right-click menu offers the same.
- A new layout, arranged like 1Password: All Items, **Review** (what may need a look: values changed since a push,
  values not pushed, grants about to end), Activity, then projects and services, then Grants and Recently Deleted.
  The list is flat and alphabetical, each row with its project and environment, with search (⌘F) and a filter for
  category, environment and access. The detail pane is a set of cards with an **Edit** menu.
- Review, Activity, Recently Deleted and Grants each show the selected entry's detail: Review findings with their
  items and a recommended action, Activity entries with who, where and the command, deleted items with restore and
  permanent delete, and grants in a table with revoke.
- **Edit Details…** changes kind, access, service, note and fill sites together, with one Touch ID.
- The sheets share one header and footer.
- List rows are two lines, the name over its project, environment and service, with the type as the icon (hover
  for its name). The header counts items, projects and services and has a **New Item** button; import and move
  are in the options menu after the filters.
- New Value, New Grant, Move to a Project and Import use the sheets' field cards and footer.

### Fixes
- Copied values stay on this Mac: Universal Clipboard no longer hands them to your other devices.
- `lk push` and `lk remote status` cover the whole environment record: shared items and plain settings go too, and
  unconfirmed variables are held back and listed. The app shows push state for a pushed shared item.
- `lk export --values` refuses a file Git tracks or doesn't ignore, and warns about folders that sync to a cloud
  service.

### Approvals
- One prompt at a time. A change asks with the macOS Touch ID sheet alone ("Latchkey is trying to add
  shop/development/DB, asked by Claude in ~/Projects/shop"); its Details… button opens the panel with everything.
  Releasing values, grants, earlier values and pushes show the panel first and ask for Touch ID after you choose.
  Before, the panel and the system sheet appeared together.
- Panels name the agent ("Claude wants to use 2 items"), with the process chain under "Asked by".
- An unanswered sheet denies without opening the panel.
- A plain-text export no longer offers "Allow from this folder", which it couldn't honour.

### App Store groundwork
- The store experiment has a dedicated, mutually authenticated CLI endpoint. Commands continue to run in the
  terminal CLI; channel selection never falls back to another broker. Dynamic Security.framework identity checks
  avoid needing sandbox access to the external CLI executable. Signed execution probes cover Node/npm, masking,
  temporary files, signals and grants; final CLI packaging, SSH and full submission gates remain pending.

### Command line
- `latchkey log` reads the access log of the Latchkey it's talking to, over its connection, so it works when that
  Latchkey keeps its log in a sandbox container or on another Mac over SSH. It needs an updated app; `--limit` takes
  0 to 1000.
- The tool picks its broker once (`LATCHKEY_BROKER`: auto, direct or app-store) and never falls back to another.
  `LATCHKEY_LOCAL_SOCKET` points it at a local socket for development, still checking the app's signature.
- Caller details are read between two checks of the process's start time, so a reused process ID can't lend another
  process's folder or command to a request.

## 0.1.0 (2026-11-11)

The first release.

### Environments on every Mac
- Each environment has a synced record of its variables: items (shared items too) or plain settings such as
  `PORT=3000`. `latchkey run --env` reads it, so a shared item still loads when the checkout is somewhere else, as on
  another Mac. Until `latchkey env migrate` has checked an environment, the older path-based lookup still fills gaps,
  and says so.
- `latchkey env` lists, shows, sets, unsets, confirms and removes records; `env migrate` makes them from your items and the
  files they came from. It only adds, marks what it found through file locations as unconfirmed, and reports
  conflicts, missing items, missing files and plain values that may be secret.
- Import, `set` and `mv` keep records current.
- `latchkey export PROJECT/ENV` writes an environment's env file of references. `--values` writes values in plain
  text: it asks every time naming the file, writes it owner-only and whole, refuses symbolic links, and is logged
  without the values.
- `latchkey project` matches a checkout to its project by Git remote; `project link` remembers a project's remote.
  Import names items after a linked project, so a clone under another folder name keeps its project.
- MCP: `latchkey_project` and `latchkey_export_references`, which never return values.

### Approvals and setup
- The Touch ID sheet says only what's asked ("Latchkey is trying to add shop/development/DB for claude"); the
  approval panel above it still shows the caller, folder and command.
- After an import, the next-steps sheet offers a prompt to copy into an agent's instructions.
- The window shows changes made on your other Macs: it looks again when Latchkey comes to the front and every 30
  seconds while a window is open. Before, an open window kept showing an item deleted on another Mac.

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

### Distribution
- Developer ID-signed and notarized, in a disk image, with the command-line tool inside the app
  (**Latchkey › Install Command Line Tool…**, which also adds `lk`).
- A Homebrew cask, written by the release script.

### Docs
- Nine credential use cases (`docs/cases`) and a design proposal for Authority Manifest and delegated staging
  deploys (`docs/authority-manifest-integration.md`). Neither describes shipped behavior.
