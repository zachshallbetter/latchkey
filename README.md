# Latchkey

A secrets manager for one person's Macs and the agents running on them. "Latchkey" is a working name.

Files hold references (`latchkey://NAME`), the app holds the values, and `latchkey run` swaps them in when a
command starts. Agents get only the items marked agent-safe; everything else needs approval in the app.

## Status

| Part | State |
|---|---|
| `LatchkeyCore` library: references, `.env` parsing, output masking, wire protocol, caller identification | Built |
| Keychain storage: iCloud Keychain when signed, login keychain otherwise | Built |
| Broker: agent-safe policy, approval panel then Touch ID / Apple Watch / password, grants, access log | Built |
| Projects, environments and services: item IDs `project/environment/NAME`, import placement, moving items, project-wide grants | Built |
| Version history: earlier values kept on change and delete, restore, Recently Deleted for 30 days | Built |
| Remote locations: link an environment to Vercel, GitHub Actions, Railway or Fly; names-only status; push | Built (Fly untested: `flyctl` not installed here) |
| `latchkey` command-line tool: `run`, `list`, `get`, `set`, `rm`, `update`, `import`, `mv`, `history`, `restore`, `deleted`, `forget`, `remote`, `push`, `grant`, `grants`, `revoke`, `status`; starts the app if needed | Built |
| `latchkey-broker`: the broker without a window, for development | Built |
| App: window with sidebar, item list and detail; reveal and copy behind Touch ID; .env import sheet; activity log; menu bar panel; settings; open at login. Hosts the broker | Built; needs a team set to sync |
| Key-file delivery (`--file`, `latchkey-file://`) | Built |
| Expiry reminders | Not built |
| Browser extension or AutoFill provider | Not built |
| SSH agent (Secure Enclave keys) | Not built |

Tests: 59 (`swift test`; add `LATCHKEY_KEYCHAIN_TESTS=1` to include a real keychain round trip).

See [docs/apple-passwords-and-passkeys.md](docs/apple-passwords-and-passkeys.md) for how this uses iCloud Keychain
and LocalAuthentication, why items don't appear in the Passwords app, and where passkeys fit.

## Install

    scripts/install.sh

Builds both, installs `/Applications/Latchkey.app` and `~/.local/bin/latchkey`, then starts the app. Run it
again after pulling changes. The command-line tool starts the app if it isn't running (set
`LATCHKEY_NO_LAUNCH=1` to turn that off); **Open Latchkey at login** in Settings avoids the wait.

Without `DEVELOPMENT_TEAM` in `App/project.yml`, the app is signed ad hoc and keeps values in this Mac's login
keychain. Each reinstall changes the ad hoc signature, so macOS asks for your login password once per item the
first time the new copy reads it (choose **Always Allow**). Signing with your team fixes that and turns on iCloud
Keychain sync: see [docs/apple-passwords-and-passkeys.md](docs/apple-passwords-and-passkeys.md#setting-up-a-new-mac).

## Approvals and grants

Reading an item that isn't agent-safe from a command shows Latchkey's approval panel: the items, the program
asking (for example `zsh › claude`), its folder and its command. Choose **Deny**, **Allow Once**, or **Allow from
this folder for** 1 hour to 7 days. Touch ID, Apple Watch or your password then confirms the choice. Requests you
make in the Latchkey window go straight to Touch ID. An unanswered panel counts as a denial after 90 seconds.

A **grant** lets commands run from one folder, and the folders inside it, read some items without asking until
it ends. Make one from the approval panel, from **Grants** in the window, or ahead of time before you leave an
agent working:

    latchkey grant DATABASE_URL,STRIPE_KEY --folder ~/Projects/site --for 2h
    latchkey grants
    latchkey revoke 3f9a1c        # or: latchkey revoke all

Grants are kept on this Mac only (`~/Library/Application Support/Latchkey/grants.json`), last at most 7 days,
and show up in Activity when they're made, used and revoked. A grant for a repository's folder also covers its
git worktrees, wherever they live (`~/Projects/_worktrees/site/fix-login` is covered by a grant for
`~/Projects/site`).

## Running commands

    latchkey run --env-file .env.local -- npm run dev          # references in a file
    latchkey run --env acp/development -- npm test              # an environment, no file needed
    latchkey run --env acp/development --file ASC_KEY_PATH=acp/production/ASC_P8 -- fastlane beta

- `--env PROJECT/ENV` sets each of the environment's items as its name, plus the shared items that environment's
  files use (as recorded on import). Repeat it to combine environments. Fresh worktrees have no `.env` (it's
  gitignored); this needs none.
- `--file NAME=ID`, or `NAME=latchkey-file://ID` in an env file, gives the command the path of a temporary file
  holding the value, readable only by you and deleted when the command exits. For tools that want a file: App Store
  Connect `.p8` keys, a gcloud service-account JSON, a TLS key.

Exit codes, for scripts and agents:

| Code | Meaning |
|---|---|
| 0 | Done |
| 64 | Wrong usage |
| 66 | No item with that ID. Ask the owner to add it; don't retry. |
| 69 | The Latchkey app can't be reached |
| 73 | A file couldn't be rewritten |
| 77 | Refused: not agent-safe, not approved, no grant. Ask the owner to approve or grant; don't retry. |
| 127 | The command couldn't start |

Refusals and missing items print the item IDs and the grant command that would allow them.

## Projects, environments and services

An item is either **shared** (ID `GEMINI_API_KEY`) or belongs to one **environment** of a **project**
(ID `acp/production/DATABASE_URL`). Files refer to items by ID: `latchkey://acp/production/DATABASE_URL`. The
same name can hold a different value in each environment, and two projects never collide.

- **Environments** are free-form names. development, preview, staging, production and test get their own colours and
  sort first; anything else (`pr-123`, `eu-west`) works too.
- **Service** is the provider that issued a value (Neon, Stripe, GitHub…). It's metadata, not part of the ID, so
  changing it never breaks a reference. Import fills it in from the value's shape (`sk_live_`, `ghp_`), the host in
  a connection string (`neon.tech`) or the key's name (`STRIPE_`), and you can edit it.
- **Used in** records the files an item was imported from, so moving it can update their references.

The project and environment, and whether an item is shared, are part of its ID and nothing else, so grouping
can't drift from the references. Service and "used in" travel with the item in iCloud Keychain.

    latchkey import apps/web/.env.local --dry-run       # project = repo folder, environment = development
    latchkey import .env.production --project acp --rewrite
    latchkey list --project acp
    latchkey mv --from-file ~/Projects/acp/.env.local --to acp/development   # move shared items a file refers to
    latchkey grant 'acp/production/*' --folder ~/Projects/acp --for 2h
    latchkey update 'acp/*' --agent-safe no                                  # many items, one approval
    latchkey rm 'old-project/*'

## History and recovery

When a value is replaced (`set`, Change Value, `import --replace`, a restore) the old value is kept as a version,
with when and by whom. Deleting an item keeps its value too, in **Recently Deleted**, for 30 days. Versions are
keychain items in the same keychain and access group as the items, so they sync the same way; moving an item takes
its history with it. Each item keeps its last 10 versions.

Showing an earlier value or restoring one always asks for approval (grants and agent-safe don't cover history).
Restoring keeps the current value as a version first.

    latchkey history acp/production/DATABASE_URL
    latchkey restore acp/production/DATABASE_URL --version 2
    latchkey deleted
    latchkey forget acp/production/DATABASE_URL      # earlier values gone for good

## Remote locations

Link an environment to the places that hold its values, then push from Latchkey instead of pasting into each
dashboard:

    latchkey remote link acp/vercel.preview vercel project=acp environment=preview
    latchkey remote link acp/production github repo=me/acp environment=production
    latchkey remote link acp/railway.production railway environment=production service=api dir=~/Projects/acp
    latchkey remote link acp/production fly app=acp-api
    latchkey remote status acp/production      # names missing on each side, values changed since the last push
    latchkey push acp/production --dry-run
    latchkey push acp/production

- A link covers the whole environment, including items added later.
- **Values that differ by service** live in their own environment: `acp/vercel.preview` beside `acp/preview` (used
  locally). The app shows `vercel.preview` as "Vercel · preview".
- Pushes use each service's own tool, signed in as you (`vercel env add`, `gh secret set`, `railway variable set
  --stdin --skip-deploys`, `flyctl secrets import --stage`). Values go on standard input, never in arguments.
  Nothing is deployed: new values apply on the next deploy, which you start.
- Every push asks, every time; no grant or remembered approval covers it. Production (Vercel production, a
  GitHub or Railway environment named like production, a Fly app) needs an extra confirmation in the panel on top of
  Touch ID. Pushes run only in the app; `latchkey-broker` refuses them.
- Status reads names only. Railway's listing includes values; Latchkey keeps the names and drops the rest.
- Links are synced with your items. Each records when each item was last pushed, so items changed since show as out
  of date.

## Using the app

- **Sidebar:** All, Agent-Safe, Ask First and Activity, a count per kind, then **Projects** (with a filter once there
  are many), **Shared** and **Services**.
- **Lists:** a tree, never a flat list of every key. Views that span projects (All, Agent-Safe, a kind or a
  service) show projects, then environments, then items; a project's own view starts at its environments. Groups
  start closed and show their counts and environments while closed; while you search they start open. A click
  always opens or closes one. Right-click a project or environment header for actions on everything in it.
- **Several items:** select with ⌘-click or ⇧-click. The detail pane and the right-click menu then act on all of
  them with one approval: require approval or let agents read, set kind or service, move, grant access, delete.
- **A whole project:** right-click it in the sidebar to select all its items, change agent access, grant access to
  the project (including items added later), move or rename it, or delete it.
- **Detail:** reveal (hides again after 30 seconds) and copy (the clipboard clears after 60 seconds) ask for
  Touch ID unless the item is agent-safe. Kind, agent-safe, note, change value and delete are there too, along
  with the item's recent activity.
- **Import:** use **File > Import .env File…** (⇧⌘I) or drop a file on the window. The sheet proposes the project
  (the repository's folder) and environment (from the file name); change them, or import as shared items. Review
  each item's kind and agent-safe setting, then approve once.
- **Move to a Project…** (item menu, the detail pane, or the **+** menu): pick items, a project and an environment,
  and the files whose references should follow; one approval.
- **Grants:** what each grant covers and when it ends; revoke one or all, or make a new one.
- **History:** each item's earlier values in its detail pane, with show and restore; **Recently Deleted** under
  Access brings deleted items back.
- **Remote:** right-click an environment for **Remote Locations…** (link, check status, push). Items show where they
  stand in the detail pane, and a badge in the list when they changed since the last push.
- **Menu bar:** search, copy a value, or jump to an item.

## Build

    swift build
    swift test

    # broker without the app (login keychain, this Mac only)
    swift run latchkey-broker

    # the app in Xcode
    cd App && xcodegen && open Latchkey.xcodeproj

Run the app or `latchkey-broker`, not both: they answer on the same socket. Only one copy of the app runs at a
time; starting another brings the running one forward.
Requires Xcode 16 or later on macOS 14 or later.

Debug builds can draw their own UI to a PNG without clicking:
`Latchkey --snapshot out.png [--select NAME] [--filter activity|grants] [--import FILE] [--part sidebar|menubar|approval] -ApplePersistenceIgnoreState YES`
(the last flag makes a copy started from a shell bring up its window).

## Moving a project's secrets in

`latchkey import` adds everything in a `.env` file with one approval, into the project and environment the file
implies (see above), and `--rewrite` swaps each value in the file for its reference:

    latchkey import .env --dry-run                 # IDs and what would happen; never values
    latchkey import .env --rewrite \
        --kind DATABASE_URL=password --kind API_HOST=value --agent-safe API_HOST

Items default to kind `token` and need approval to read. Items that already exist are skipped unless you pass
`--replace`. Empty values and values that are already references are left alone, and so are `VERCEL_OIDC_TOKEN`,
`VERCEL_*` and `TURBO_*`, which `vercel env pull` writes and which expire (`--no-default-skip` imports them,
`--skip` adds patterns). `--agent-safe-pattern 'NEXT_PUBLIC_*,VITE_*,PUBLIC_*,EXPO_PUBLIC_*'` imports names that ship
to browsers anyway as plain values agents may read, so a dev server doesn't ask for Touch ID on every start.

Many repositories at once: one review, one approval, then each file rewritten.

    find ~/Projects ~/Sites -name '.env*' -not -name '.env.example' -not -path '*/node_modules/*' > envs.txt
    latchkey import --batch envs.txt --share-identical --agent-safe-pattern 'NEXT_PUBLIC_*,VITE_*' --dry-run
    latchkey import --batch envs.txt --share-identical --agent-safe-pattern 'NEXT_PUBLIC_*,VITE_*' --rewrite

Each file lands in its own project (its repository's main checkout folder, also from a worktree) and environment
(from its name). With
`--share-identical`, a name that holds the same value in every file that has it, such as `GEMINI_API_KEY`, becomes
one shared item that every file refers to, so rotating it is one change; names whose values differ stay per
project. If two files give one ID different values (`.env` and `.env.local` in the same repository, say), that's a
conflict: neither is imported and both lines stay as they are. The dry run prints names and counts only.

To have an agent do it, tell it something like: *Run `latchkey import .env --rewrite`. Do not open, read or
print `.env`.* The agent sees names and counts only. Values go straight from the file to the app, and you still
approve the batch with Touch ID.

## Layout

    Sources/LatchkeyCore   shared library
    Sources/latchkey       command-line tool
    Tests/LatchkeyCoreTests
    Sources/latchkey-broker  broker without a window
    App/Branding/          the logo (key.svg)
    scripts/               install.sh
    App/                   the macOS menu bar app (xcodegen project.yml)
    docs/

## Item kinds

| Kind | Examples | Masked in output |
|---|---|---|
| token | API keys, access tokens | yes |
| password | passwords, connection strings | yes |
| key | SSH, GPG, .p8, .pem | yes |
| value | IP addresses, host names, account ids | no |

## Logo

The key is a Font Awesome Pro glyph (commercial license; the notice is kept inside each copy of the SVG). The source
is `App/Branding/key.svg`.

The app icon is `App/Latchkey/AppIcon.icon`, an Icon Composer document with a light and a dark appearance (macOS
draws the tinted and clear versions from them). Open it in Icon Composer (in Xcode's Applications folder) to change
colours or glass. The menu bar icon and the in-app mark are copies of the SVG in `Assets.xcassets` (`MenuBarIcon`,
`Logo`) and follow the system's light and dark themes on their own.
