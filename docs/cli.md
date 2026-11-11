# Command line

`latchkey` talks to the Latchkey app, starting it in the background if it isn't running. It never prints a value
except with `latchkey get`. `latchkey help` prints a summary.

IDs are `NAME` (shared) or `project/environment/NAME`. Where a command takes several, separate them with commas, and
where it says PATTERN you can use `project/*` or `project/environment/*`.

## Running commands

### `latchkey run [options] -- COMMAND [ARGS...]`

Starts COMMAND with every `latchkey://ID` in its environment replaced by the item's value.

| Option | |
|---|---|
| `--env-file FILE` | Load `KEY=VALUE` lines from FILE first. Repeatable. |
| `--env PROJECT/ENV` | Set each item in the environment as its name, plus the shared items that environment's files use (as recorded on import). Repeatable. |
| `--file NAME=ID` | Set NAME to the path of a temporary file holding the value. `NAME=latchkey-file://ID` in an env file does the same. The file is readable only by you and deleted when COMMAND exits. |
| `--no-masking` | Don't hide values in COMMAND's output, and start it directly. |

Items that aren't agent-safe or covered by a grant ask for approval first. Values of secret kinds that are 6
characters or longer are replaced with `<concealed by latchkey>` in COMMAND's output, including values split across
two chunks of output; multi-line values are hidden line by line.

COMMAND's exit status becomes `latchkey run`'s. If COMMAND is killed by a signal, the status is 128 plus the signal.

### `latchkey get ID`

Prints one value. Asks unless the item is agent-safe or covered by a grant.

## Items

### `latchkey list [--project P] [--json]`

IDs grouped by project and environment, with kind, service, whether agents may read them, and the note. `--json` prints
the same as JSON. Never values.

### `latchkey set ID [--kind KIND] [--agent-safe] [--note TEXT] [--service NAME]`

Adds or changes an item. The value is read from standard input, or prompted for (hidden) in a terminal. Kinds:
`token`, `password`, `key`, `value`. Asks for approval. Replacing a value keeps the old one as a version.

### `latchkey update IDS|PATTERN... [--agent-safe yes|no] [--kind KIND] [--service NAME] [--note TEXT]`

Changes settings on many items with one approval. Values are untouched. `--service ""` clears the service.

### `latchkey rm IDS|PATTERN...`

Deletes items with one approval. They go to Recently Deleted for 30 days. If any named item doesn't exist, nothing
is deleted.

### `latchkey mv IDS | --from-file FILE  --to PROJECT/ENV | --shared  [--file FILE]...`

Moves items into a project's environment, or back to shared, with one approval. Values, settings and history move with
them. References are then updated in the files the items were imported from, in each `--file`, and in the
`--from-file` file. `--from-file FILE` moves every shared item FILE refers to. If any target ID already exists,
nothing moves.

## Importing

### `latchkey import FILE... [options]`

| Option | |
|---|---|
| `--batch LIST` | Also import the files listed in LIST, one path per line (`#` comments allowed). |
| `--project P`, `--env E` | Place items here instead of what the repository and file name imply. |
| `--shared` | Import as shared items named after their keys. |
| `--share-identical` | With several files, make a name with the same value in every file one shared item. |
| `--rewrite` | Replace each imported value in its file with its reference. |
| `--replace` | Overwrite items that already exist (old values are kept as versions). |
| `--dry-run` | Show what would happen; send nothing. |
| `--only KEY,...` | Import only these keys (one file only). |
| `--kind KIND`, `--kind KEY=KIND` | Kind for all keys, or one. |
| `--agent-safe KEY,...` or `all` | Mark keys agent-safe. |
| `--agent-safe-pattern PATTERN,...` | Import matching names as agent-safe plain values. |
| `--skip PATTERN,...` | Leave matching names alone. |
| `--no-default-skip` | Import `VERCEL_OIDC_TOKEN`, `VERCEL_*` and `TURBO_*` too. |

See [Importing](import.md) for how projects and environments are chosen, and how conflicts are handled.

## History

| Command | |
|---|---|
| `latchkey history ID` | Earlier values: when, why (replaced, deleted, replaced by a restore) and by whom. Never values. |
| `latchkey restore ID [--version N]` | Put back version N (1 is the most recent), or bring back a deleted item with its settings. The current value is kept as a version first. Asks. |
| `latchkey deleted` | Items deleted in the last 30 days, with days left. |
| `latchkey forget IDS` | Delete earlier values for good. Asks. |

## Grants

| Command | |
|---|---|
| `latchkey grant IDS [--folder DIR] [--for TIME]` | Let commands run from DIR (default: here), the folders inside it and that repository's worktrees read these items without asking. TIME is like `30m`, `2h`, `1d`; default 1 hour, at most 7 days. IDS can include `project/*` and `project/environment/*`. Asks once. |
| `latchkey grants` | Grants in effect, with time left. |
| `latchkey revoke ID` or `all` | End a grant, or all of them. Doesn't ask. |

## Remote locations

| Command | |
|---|---|
| `latchkey remote list [PROJECT/ENV]` | Links, with when each was last pushed. |
| `latchkey remote link PROJECT/ENV SERVICE KEY=VALUE...` | Link an environment. SERVICE is `vercel`, `github`, `railway` or `fly`. Asks. |
| `latchkey remote unlink LINK` | Remove a link. Doesn't ask. |
| `latchkey remote status PROJECT/ENV` | Names missing on each side, and values changed since the last push. |
| `latchkey push PROJECT/ENV [--to LINK] [--only IDS] [--dry-run]` | Push values. Asks every time; production needs its own confirmation in the app. |

See [Remote locations](remote.md) for the keys each service takes.

## Status

### `latchkey status`

Where values are kept, how you approve, how many items and grants, and the socket path.

## Environment variables

| Variable | |
|---|---|
| `LATCHKEY_NO_LAUNCH=1` | Don't start the app if it isn't running; fail with exit 69 instead. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done |
| 64 | Wrong usage |
| 66 | No item with that ID |
| 69 | The Latchkey app can't be reached |
| 73 | A file couldn't be rewritten |
| 77 | Refused: not agent-safe, not approved, no grant |
| 127 | The command couldn't start |

On 66 and 77, Latchkey prints the item IDs and what to do, including the `latchkey grant` command that would allow
the refused items.
