# Importing

`latchkey import` moves values from `.env` files into Latchkey. It prints IDs and counts, never values.

## One file

```bash
latchkey import .env.local --dry-run
latchkey import .env.local --rewrite
```

- **Project**: the repository's folder name (from a worktree, the main checkout's), lowercased, with anything other
  than letters, digits, `_`, `-` and `.` turned into `-`. Override with `--project NAME`.
- **Environment**, from the file name (override with `--env NAME`):

  | File | Environment |
  |---|---|
  | `.env`, `.env.local` | development |
  | `.env.development`, `.env.dev` (and `.local`) | development |
  | `.env.production`, `.env.prod` (and `.local`) | production |
  | `.env.staging`, `.env.stage` | staging |
  | `.env.preview` | preview |
  | `.env.test`, `.env.testing` | test |
  | `.env.qa` and other names | the name itself (`qa`) |

- `--shared` imports every key as a shared item named after the key, with no project.
- `--rewrite` replaces each imported value in the file with its `latchkey://` reference. Comments, order, blank lines,
  `export`, indentation and line endings on untouched lines are kept, as are file permissions. Replaced assignments
  lose their inline comments. A quoted multiline value is replaced in full.

Import also records the file's variables in its environment's record (see [Environments](cli.md#environments)):
each imported key, and lines that already hold a `latchkey://` reference. A record that doesn't exist yet starts with
the environment's items. The whole import asks for approval once. Quoted multiline values are supported; double quotes decode `\n`,
`\r`, `\t`, `\"` and `\\`, while single quotes keep escapes literally. Values are literal: no shell
interpolation or command substitution runs. Malformed syntax refuses the entire plan before values are saved.
If a file changes while approval is pending, its saved values remain in Latchkey, but rewriting stops so your
new edits are preserved; review and import the file again.

## What's left alone

- Empty values, and values that are already `latchkey://` references.
- `VERCEL_OIDC_TOKEN`, `VERCEL_*` and `TURBO_*`, which `vercel env pull` writes and which expire. `--no-default-skip`
  imports them; `--skip PATTERN,...` adds your own patterns.
- Items that already exist, unless you pass `--replace` (the old value is kept as a version).

## Kinds, services and agent-safe

- **Kind** is guessed where it's obvious: a PEM block is a key file; names ending in `PASSWORD`, `_PASS` or `PASSWD`
  are passwords, and so are URL and DSN names whose value carries credentials. Everything else defaults to token.
  Set them with `--kind KIND` (all) or `--kind KEY=KIND` (one).
- **Service** is guessed from token prefixes (`sk_live_` is Stripe, `ghp_` is GitHub), hosts in connection strings
  (`neon.tech` is Neon) and key names (`STRIPE_`). Edit it later in the app or with `latchkey update`.
- **Agent-safe**: nothing is, unless you say so. `--agent-safe KEY,...` (or `all`) marks keys; `--agent-safe-pattern
  'NEXT_PUBLIC_*,VITE_*,PUBLIC_*,EXPO_PUBLIC_*'` imports matching names as agent-safe plain values, since they ship
  to browsers anyway.

## Many files at once

```bash
latchkey import --scan ~/Projects --share-identical --agent-safe-pattern 'NEXT_PUBLIC_*,VITE_*' --dry-run
latchkey import --scan ~/Projects --share-identical --agent-safe-pattern 'NEXT_PUBLIC_*,VITE_*' --rewrite
```

`--scan` finds every `.env` and `.env.*` under the folder, four levels deep, and skips examples and templates
(`.env.example`, `.sample`, `.template`), backups (`.bak`, `.old`, `.orig`, even with a date after them), and
`node_modules`, `.git`, build and other dependency folders. It doesn't follow symbolic links. Read the dry run first:
folders inside one repository that use the same environment show up as conflicts, and nothing conflicting is
imported; give those files their own `--project` in separate imports.

To choose the files yourself, list them (`latchkey import a/.env b/.env.local`) or put them in a file, one per line,
and pass `--batch envs.txt`.

- Each file goes into its own project and environment.
- The dry run shows, per file, where it goes and how many items, shared values, skips and conflicts; then the totals.
- One approval imports everything; `--rewrite` then updates each file for the values that were saved.
- `--share-identical`: a name with the same value in every file that has it (two files or more), such as
  `GEMINI_API_KEY`, becomes one shared item every file refers to. Rotating it is then one change. Names whose values
  differ stay per project.
- **Conflicts**: if two files give one ID different values (`.env` and `.env.local` in the same repository, say),
  neither is imported and both lines stay as they are. The dry run lists them.

## In the app

**File › Import .env File…** or drop a file on the window. The sheet does the same as a single-file import, with the
project, environment, kinds and agent-safe settings editable before you approve.

## If something goes wrong

- A rewritten file holds only references. If you then delete those items, the values are in **Recently Deleted** for
  30 days: restore them there.
- An import that was interrupted can be run again: items that already exist are skipped, and only saved values are
  rewritten.
- To undo an import, delete the items (they go to Recently Deleted) and put the file back from your editor or version
  control. Latchkey doesn't keep a copy of the file.
