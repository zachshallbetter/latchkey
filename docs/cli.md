# Command line

`latchkey` (or `lk` for short) talks to the Latchkey app, starting it in the background if it isn't running. It never prints a value
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
| `--proxy` | Keep `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` out of COMMAND entirely (see below). |
| `--aws-session`, `--aws-role ARN`, `--aws-for TIME` | Give COMMAND short-lived AWS credentials instead of the long-lived key (see below). |

Items that aren't agent-safe or covered by a grant ask for approval first. Values of secret kinds that are 6
characters or longer are replaced with `<concealed by latchkey>` in COMMAND's output, including values split across
two chunks of output; multi-line values are hidden line by line.

COMMAND's exit status becomes `latchkey run`'s. If COMMAND is killed by a signal, the status is 128 plus the signal.

### `latchkey check [--env-file FILE]... [--env PROJECT/ENV]... [--file NAME=ID]... [IDS] [--json]`

What `latchkey run` with the same options would get without asking (agent-safe, covered by a grant, or approved
in the last few minutes), what would ask you, and what's missing. Asks nothing and releases nothing. Exits 66 if an
item is missing, otherwise 0.

### `latchkey mcp`

Serves Latchkey's tools to an agent over MCP, on standard input and output. See
[Latchkey's MCP server](agents.md#latchkeys-mcp-server).

### Keys that never reach the command (`--proxy`)

With `--proxy`, a variable that is exactly a reference to an OpenAI or Anthropic key gets a placeholder instead, and
`OPENAI_BASE_URL` or `ANTHROPIC_BASE_URL` points at a port on this Mac that `latchkey run` listens on. Requests there
that carry the placeholder go to `api.openai.com` or `api.anthropic.com` with the real key in its place; anything
else is refused. The real key stays in `latchkey run`, so COMMAND can use it but can't read, print or send it
anywhere else.

```bash
latchkey run --proxy --env shop/development -- npm test
```

It works with programs that use the OpenAI or Anthropic SDKs (or read those base URL variables). If a base URL
variable is already set, that provider's key is passed through as usual.

### Short-lived AWS credentials

With `--aws-session`, `latchkey run` signs a request to AWS STS with your long-lived access key (`AWS_ACCESS_KEY_ID`
and `AWS_SECRET_ACCESS_KEY`, both `latchkey://` references) and gives COMMAND the temporary credentials STS returns:
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and `AWS_CREDENTIAL_EXPIRATION`. `--aws-role ARN`
assumes that role instead. They last 15 minutes unless `--aws-for` says otherwise (at most 12 hours), so a leaked
value soon stops working. The long-lived key never reaches COMMAND. No AWS CLI is needed. MFA isn't supported yet.

```bash
latchkey run --aws-role arn:aws:iam::123456789012:role/dev --aws-for 1h --env shop/development -- terraform plan
```

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
| `latchkey grant IDS [--folder DIR] [--for TIME] [--session] [--command CMD]... [--once]` | Let commands run from DIR (default: here), the folders inside it and that repository's worktrees read these items without asking. TIME is like `30m`, `2h`, `1d`; default 1 hour, at most 7 days. IDS can include `project/*` and `project/environment/*`. Asks once. |
| `latchkey grants` | Grants in effect, with time left and any limits. |
| `latchkey revoke ID` or `all` | End a grant, or all of them. Doesn't ask. |

Narrow a grant further with any of:

- `--session`: it ends when the agent you run `latchkey grant` under quits (the nearest program that isn't a shell,
  such as `claude`), and covers only programs started under it.
- `--command CMD`: only `latchkey run` of that command. `--command "npm test"` covers `npm test -- --ci`, not
  `npm run dev`. Repeat it for several commands. Only Latchkey's own signed tool can use it, since the app reads the
  command from its command line.
- `--once`: it ends after one request.

The approval panel offers the same: **until claude quits** in the list, and **Only for …** for the command being run.

## Rotating

| Command | |
|---|---|
| `latchkey touched [--since 24h] [--by NAME] [--grant ID] [--json]` | Items Latchkey released in that time: to anything, to programs under NAME (such as `claude`), or under one grant. From the access log; never values. |
| `latchkey rotate IDS\|PATTERN... \| --touched [...] [--open] [--push]` | Replace items one by one: ends grants that cover them, shows where to make each new key (`--open` opens the page), asks for the new value (the old one stays in history), then pushes to linked environments with `--push`. |

After an agent session:

```bash
latchkey touched --since 4h --by claude
latchkey rotate --touched --since 4h --by claude --open --push
```

Latchkey can't make the new key for you: Stripe, GitHub, OpenAI and most services only issue keys in their
dashboards. It takes you to the page, saves what you paste, and puts it everywhere it's linked.

## Remote locations

| Command | |
|---|---|
| `latchkey remote list [PROJECT/ENV]` | Links, with when each was last pushed. |
| `latchkey remote link PROJECT/ENV SERVICE KEY=VALUE...` | Link an environment. SERVICE is `vercel`, `github`, `railway` or `fly`. Asks. |
| `latchkey remote unlink LINK` | Remove a link. Doesn't ask. |
| `latchkey remote status PROJECT/ENV` | Names missing on each side, and values changed since the last push. |
| `latchkey push PROJECT/ENV [--to LINK] [--only IDS] [--dry-run]` | Push values. Asks every time; production needs its own confirmation in the app. |

See [Remote locations](remote.md) for the keys each service takes.

## The log

| Command | |
|---|---|
| `latchkey log [--limit 20]` | Recent access log entries: time, what, decision, items, who, folder and command. Never values. |
| `latchkey log --verify` | Checks the log's chain: exits 0 if every entry is as Latchkey wrote it, 1 with the first line that isn't. |

## Status

### `latchkey status`

Where values are kept, how you approve, how many items and grants, and the socket path.

## Environment variables

| Variable | |
|---|---|
| `LATCHKEY_NO_LAUNCH=1` | Don't start the app if it isn't running; fail with exit 69 instead. |
| `LATCHKEY_SOCKET=PATH` | Connect to a socket forwarded over SSH from the Mac running Latchkey (see [From another Mac over SSH](agents.md#from-another-mac-over-ssh)). |

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
