# Changelog

## Unreleased

### CLI
- Every `LATCHKEY_` environment variable can also be set as `PISTACHIO_` (`PISTACHIO_SOCKET`, `PISTACHIO_BROKER`,
  `PISTACHIO_NO_LAUNCH` and the rest), which wins when both are set. The old names keep working.
- The MCP tools are renamed `pistachio_run`, `pistachio_check`, `pistachio_list`, `pistachio_status`,
  `pistachio_project`, `pistachio_request_grant` and `pistachio_export_references`. The `latchkey_` names are listed
  beside them and work the same until the next release. `pistachio_request_grant` no longer says requests are
  limited to a day, which stopped being true in 0.4.0.
- The command-line tool also answers to `pistachio`, the product's name after the rename: Install Command Line Tool,
  `scripts/install.sh` and Homebrew link it beside `latchkey` and `lk`. All three are the same signed tool, so grants
  for `latchkey run` and `lk run` cover `pistachio run` too, and `latchkey` and `lk` keep working.
- Env files can use `pistachio://ID` and `pistachio-file://ID` as well as `latchkey://ID` and `latchkey-file://ID`,
  ahead of the rename to Pistachio. Both mean the same and always will, so existing files keep working unchanged.

## 0.4.0 (2026-11-18)

### App
- Grants can last until you revoke them: **until revoked** in the approval panel and New Grant, or `latchkey grant
  … --for always`. The 7-day limit is gone, and so is the one-day limit on grants an agent asks for through MCP (they
  still end when the agent quits). A grant until the agent quits no longer also ends after a day.
- Latchkey locks, as Passwords does: when it opens, after 5 minutes in the background (1, 5, 15 or 60 in Settings ›
  Privacy), and when the Mac sleeps or the screen locks. Touch ID is asked for right in the lock screen, with no
  system sheet; **Use Password…** opens the sheet for the Mac password. While locked the window and Settings show
  nothing but the lock screen, and the menu bar panel lists nothing but unlocks with Touch ID right there.
  **Lock Latchkey** (⌃⌘L) and **Lock** in the menu bar panel lock it by hand. The lock covers the app only:
  approvals for commands, agents and Safari still appear while it is locked.
- Keyboard focus rings no longer appear on buttons and controls anywhere in the app.
- Approvals are one small panel with Touch ID inside it, for releases and changes alike; **Use Password…** opens the
  system sheet. Requests from the same agent in the same folder that arrive while it's up join it as rows, so one
  touch answers a burst; each row can be denied on its own. Pushes, SSH, Safari and unidentified programs are still
  asked on their own.
- A new remote location, **SSH**, pushes to a credential script on a Linux host over your ssh connection, one item
  per credential (`ADAPTER.ACCOUNT`) with the value on standard input: `latchkey remote link distribution/production
  ssh host=titan script=/path/to/add-credential.sh`. It always counts as production, its status comes from
  Latchkey's push record, and the direct download only (#96).
- **What's New** shows each version's changes once after it updates, and again from **Latchkey › What's New in
  Latchkey…** or Settings › About. Update notices from the direct download show the same notes.
- The Upgrade sheet describes each Pro group with its planned features, as the site does, and says the core
  never depends on Pro instead of promising it stays free.
- The item list is in sections: by project in All Items (Shared first), by environment in a project, or by service or
  type from **Group By** in the list's menu. Each section is a compact row like the sidebar's, with its icon and count,
  that opens or folds; past eight sections they start folded. Rows no longer repeat what their section says.
- A Review finding lists its items by project inside its card, folded when there are more than eight places, so a
  finding covering hundreds of items reads as a list of places with counts.
- The sidebar's project list has a filter field once there are more than a dozen projects.
- Project and service icons sit on a tile that follows light and dark mode; an icon that is already a filled square
  (an app icon) is drawn without a white frame, and a dark logo keeps a light tile in dark mode so it stays visible.

- Settings has its own window with a tab for each section (General, Privacy, Storage, Developer, Membership,
  About), instead of a column in the main window that looked like the item list. **Settings…** at the bottom of the
  sidebar, ⌘, and the menu bar panel open it.
- Settings › Developer shows the command-line tool when it's installed outside the app (`scripts/install.sh`,
  Homebrew), instead of saying there isn't one.
- About shows the copyright, licence and website, and the direct download's About panel has its copyright line.
- Clicking the menu bar key opens the window; right-clicking (or Control-clicking) it shows the quick panel. The
  panel's item list is sized to its items instead of collapsing to a sliver, and the key has room around it.
- Quitting with ⌘Q now leaves Latchkey in the menu bar too, under the same setting as quitting from the Dock (now
  **Keep running in the menu bar when I quit**). Quit in the menu bar panel, logging out and scripts still quit it.
- Settings › Developer Tools shows whether Latchkey for Safari is on and opens Safari's Extensions settings with it
  selected, so it can be turned on from the app.
- `scripts/install.sh` now forgets every other copy of the app macOS has registered (other worktrees' builds,
  Xcode archives), not just its own build folder. With stale copies registered, Safari could resolve Latchkey's
  extension to one of them and **Turn On in Safari…** failed with SFErrorDomain error 1.

### Security
- Grants no longer have a maximum length. A grant until revoked keeps working until you revoke it; Grants and
  `latchkey grants` show it as "until revoked".
- The broker no longer holds its lock while a request waits for approval. The request runs again after the answer
  and uses it only for the same question about unchanged values; anything else asks again.
- Approvals show what they allow. The panel lists every item asked for, with a count, and the whole command a signed
  `latchkey run` starts, unredacted and never cut off in the middle. Text a caller supplies (a service name, a link
  label) can no longer end the Touch ID sheet's description early. A caller Latchkey can't identify is named as
  unidentified, with the warning and the panel first, instead of passing for Latchkey's own tool.
- Environment approvals name what each variable will resolve to, and link and push approvals name the Railway project,
  Vercel team and working folder that decide where values go.
- `combine` asks before comparing values, so whether two secrets match is never answered without approval.
- A forged `.git` file or a `.git` symlink to another checkout no longer makes a folder count as that repository, so a
  grant can't reach it.
- MCP `latchkey_export_references` writes only in the folder the server started in, inside it, or a worktree of its
  repository; an agent-chosen `cwd` elsewhere is refused.
- `remote-status` errors never quote a service tool's list output, which can hold values. A push refuses a variable
  name that isn't a valid identifier on every route, including names in records synced from another Mac.
- Grants and the access-log keys are read only from this Mac's own keychain items, never a synced one, and a revoke
  that can't be saved says so instead of reporting success.
- Rewriting references in a symlinked env file rewrites the file it points to, keeping its permissions, instead of
  replacing the link. The export check for Git looks through symlinks, and `scan --install-hook` won't write outside
  the repository's `.git` folder.
- The grant command suggested after a refused run quotes the folder when its name has anything but ordinary path
  characters, so a folder name can't turn into shell syntax when the command is pasted.

### Mac App Store
- The App Store version leaves out GitHub Actions pushes, so it uses only Apple's encryption and needs no export
  documents. GitHub's sealed box moved to its own library, `LatchkeySeal`, which the direct download and its tests
  link; the store build offers Vercel, Railway and Fly, and refuses a synced GitHub link's push before sending
  anything.
- Its window no longer names GitHub Actions where it lists the services it pushes to, and its screenshots' sample
  data links Railway instead.
- `scripts/release-appstore.py` checks what App Store Connect receives: the package's installer signature and the
  distribution-signed app inside it (`appstore-preflight.py --distribution`), then lists the submission gates still
  open. Build 6.

### Site
- The privacy policy says the App Store version doesn't push to GitHub, and the pricing page lists pushes to
  deployment platforms as free, as they are today.

## 0.3.1 (2026-11-13)

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
- More headlines act out what they say, one per page: "Migration" slides in on Teams, "stops" stops dead on
  Security, "next" fills in on the Roadmap, "Free" holds in the accent colour on Pricing, and "References" (API) and
  "no page" (404) are drawn as dashed placeholders. Each guide's headline does the same with its own word ("Block"
  stops dead, "out" and "Push" move, "API keys" and ".env" are placeholders), and so do the docs ("Quickstart" moves,
  "Agents" fills in). Support, Privacy and Terms keep plain headlines, since those are what people look for; their
  repeated labels are gone, Support is titled "Support and troubleshooting", and "stays" in Privacy's "What stays on
  your Macs" holds in the accent colour.
- A `latchkey://` reference in prose is drawn as a dashed placeholder, with a hover note that the value is filled in
  when a command starts; on Features, "filled in" arrives masked and then fills in, once, unless motion is reduced.
- Headings say what each section holds instead of generic lines ("Everything in one window", "Three ways in",
  "What would make Latchkey excellent"); labels that repeated their headings are gone; the hero glow, the closing
  band's three-colour glow, the Pro cards' gradients and the frosted header are flat.
- Pro's four groups are described with their planned roadmap items: secret requests and a hook that stops `cat .env`;
  last-used and expiry dates, reminders and leak alerts; importers and an encrypted backup; each key's origin. The
  core is described as meant to stay free rather than free for good; storing, reading and exporting your own values
  still never depend on Pro. Opening **For agents** no longer moves the hero's scene.
- End-to-end audit: Lighthouse, WCAG 2.0 AA with axe-core, a crawl and a reader's review. Fixes: scene pause buttons
  are reachable by keyboard and screen readers, the home page no longer shifts on phones as its scene lays out, the
  404's terminal passes contrast in light mode, drawings no longer break the heading outline, pages swap without a
  fade, and the comparison table names included and not-included cells. Copy now matches what's shipped: the source
  is public, the notarized release exists, the Mac App Store version is still to come, the Homebrew cask adds the
  command-line tool, and the CLI's real "cannot reach the Latchkey app" message.
- A **For humans / For agents** switch under the home page's buttons gives the line to point a coding agent at
  `llms.txt`, which now covers everything an agent needs in one file. Every footer links to it.
- Thirteen new guides, checked against the CLI's source: blocking secrets at commit, fresh clones and worktrees,
  duplicate keys, merging into an existing env file, pasting into a dashboard, the key proxy, rotating after an agent
  session, short-lived AWS credentials, App Store Connect keys with fastlane, pushing to deployment platforms, SSH,
  saving keys from Safari, and auditing access. The guides index groups all sixteen into four categories.
- The docs and guides share one sidebar with icons that stays in place between pages: it sticks under the header, the
  scrollbar's space is reserved so nothing shifts, and supporting browsers keep it still while the content changes.
  The footer's docs link reads Developers.
- The header has a Guides tab, and Docs is now Developers. It stays one row at every width, dropping How it works and
  Security below 1000px, the download button below 720px and Features below 480px.
- Guides use the developer docs' layout, with a Guides sidebar, breadcrumbs and contents. The architecture diagram on
  the docs overview is drawn top to bottom so it no longer wraps.
- Phone pass: the pricing comparison stacks each row, inline code breaks only at spaces and keeps flags whole, docs
  breadcrumbs and "On this page" links and the footer byline are larger tap targets, the closing band drops its
  first sentence, and roadmap labels are 12px.
- Search and authorship: descriptive titles under 66 characters, a social card per page, author metadata and a
  JSON-LD graph on every page naming Zach Shallbetter (with the person and studio IDs Snack Studio's other sites use),
  a footer byline, a "Who makes Latchkey" section, `humans.txt`, browser icons and a web manifest from the app icon,
  `llms-full.txt`, an IndexNow key, and three guides (env files, coding agents, MCP server configs).
  `scripts/discovery.py` replaces `scripts/sitemap.py`; `scripts/social-images.py` renders the cards.
- A quieter home page header: the title in one colour with its second sentence muted on its own line, a two-sentence
  introduction, the buttons, and one line of facts; the scene's caption is one line. The social image matches.
- A footer with the download and Product, Developers and Trust and help columns on every page, and a 404 page that
  shows what `lk get` prints for a name it doesn't have, with links onward.
- Digital Presence Protocol pass: a social preview image and large card on every page, descriptions under 170
  characters, breadcrumbs on every page and one organization, website and app graph on the home page, a sitemap with
  each page's last change (`scripts/sitemap.py`), a 404 page, a route for reporting mistakes and a changelog link in
  every footer. `docs/presence.md` records the entities, claims and their evidence, surfaces, access checks, and the
  metrics and query panel still to run. Pricing no longer says the source "will be" available: it is.
- Layout pass: no single words on their own line, card links and plan buttons line up across each row, availability
  labels sit beside each card's symbol, and the lightest cards gained a real example or detail.
- The app window on the home page and Features follows the app's current layout: sidebar with Review and the
  iCloud Keychain badge, a flat list with search, filters and the app's type icons, and the detail as cards with
  recent activity. One icon set, after the app's SF Symbols, gives every card, button and fact a symbol.
- Every code block explains its parts on hover or focus, not only `lk` lines: Features examples, CLI synopses and
  their placeholders, env files, JSON, `brew`, `ssh`, `claude` and `export`, the agent note and the architecture
  diagram.
- More colour: each section takes a hue (eyebrow, steps, scene wash), the hero line and closing band
  carry a gradient, and Pro is orange as in the app's upgrade sheet.
- Caught up with the product: Features, the Roadmap, the CLI and agent docs and `llms.txt` cover `lk scan` and its
  pre-commit hook, duplicates and combine, import classes, export merge and clipboard, the proxy's limits and
  updates. Pro's four groups use the app's own wording, and duplicates, scanning, rotation and pushing are listed as
  free.
- Free leads: every primary button is **Download free**, the home page and Features show what Pro adds
  (marked planned), and Pricing lists Pro's features in place of four labels.
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
