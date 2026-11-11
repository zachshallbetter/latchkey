# Using with agents

Coding agents need your API keys and database URLs to run tests and dev servers. With Latchkey they get them through
`latchkey run`: the values reach the command, not the agent's files, and you decide which values an agent may use
without asking.

## The pattern

1. Keep references in your env files (`latchkey import .env.local --rewrite` does this).
2. Run anything that needs secrets through `latchkey run`:

   ```bash
   latchkey run --env-file .env.local -- npm test
   latchkey run --env shop/development -- npm run dev       # no env file needed
   ```

3. Decide what an agent may read without you:
   - **Agent-safe** items, for values that aren't really secret.
   - **Grants**, for a folder and a time: `latchkey grant 'shop/development/*' --folder ~/Projects/shop --for 2h`.
   - Everything else asks you, with the agent's process chain, folder and command shown.

Fresh git worktrees and clones don't have your `.env` (it's gitignored). `latchkey project` says which project the
checkout is; `latchkey export PROJECT/ENV --out .env.local` writes an env file of references from the environment's
record, with no values in it; `latchkey run --env PROJECT/ENV` loads the environment without any file. A grant for a
repository's folder covers its worktrees.

## Skills and plugins

The Latchkey skill (`plugins/latchkey/skills/latchkey/SKILL.md`) tells an agent everything below: run commands
through `lk run`, check before a slow run, never print or write a value, put references in env files, give the
person the `lk set` command for a missing key, suggest a session grant when they step away, and stop on 77 or 66.

- **Claude Code:** the plugin installs the skill and registers `lk mcp` as an MCP server.

  ```
  /plugin install latchkey --marketplace zachshallbetter/latchkey
  ```

  The MCP server is started as `lk`, so `~/.local/bin` must be on the `PATH` Claude Code starts with.
- **Codex CLI, Gemini CLI, Cursor and other tools that read the Agent Skills format:** copy the
  `plugins/latchkey/skills/latchkey` folder into the skills folder your tool reads (for example, `.agents/skills/`
  in a project for Codex).
- **Claude Desktop and other MCP clients without a shell:** add `lk mcp` as a local MCP server (see
  [Latchkey's MCP server](#latchkeys-mcp-server)). Chat apps that only reach MCP servers on the internet can't use
  Latchkey: its MCP server runs on your Mac.

The marketplace install works once the repository is public; until then, add the plugin from a local checkout
(`/plugin marketplace add /path/to/latchkey`).

## Instructions to give an agent

Without the skill, put something like this in your agent instructions (`CLAUDE.md`, `AGENTS.md` or similar):

> Secrets are in Latchkey. Env files hold `latchkey://` references, not values. Run anything that needs secrets as
> `latchkey run --env-file .env.local -- <command>` or `latchkey run --env <project>/<environment> -- <command>`.
> Never run `latchkey get`, never print the environment, and never read or write values in `.env` files. If
> `latchkey` exits with 77 (refused) or 66 (missing), stop and ask; don't retry.

## Exit codes

| Code | Meaning | What an agent should do |
|---|---|---|
| 0 | Done | |
| 64 | Wrong usage | Fix the command |
| 66 | No item with that ID | Stop; ask the person to add it |
| 69 | The Latchkey app can't be reached | Stop; ask the person to open Latchkey |
| 73 | A file couldn't be rewritten | Stop and report |
| 77 | Refused: not agent-safe, not approved, no grant | Stop; ask the person to approve or grant. Don't retry |
| 127 | The command couldn't start | Fix the command |

On 77 and 66, Latchkey prints the item IDs and, for 77, the exact `latchkey grant` command that would allow them.

## Leaving an agent working

Before you step away, grant what the job needs, as narrowly as it allows. Run these inside the agent's session (in
Claude Code, start the line with `!`) so `--session` ties to the agent:

```bash
latchkey grant 'shop/development/*' --session --for 4h                    # ends when the agent quits
latchkey grant 'shop/development/*' --command "npm test" --for 2h         # only this command
latchkey grant 'shop/development/*' --folder ~/Projects/shop --for 2h     # the folder, for a time
```

The agent's reads go through without asking until the grant ends, and each one is in Activity. Revoke it early from
**Grants** in the app or with `latchkey revoke ID`.

## Keys an agent can use but never read

For OpenAI and Anthropic keys, `latchkey run --proxy` gives the command a placeholder and a local base URL, and adds
the real key only to requests to the provider. An agent's command can call the API, but can't print, encode or send
the key anywhere else. See [`--proxy`](cli.md#keys-that-never-reach-the-command---proxy).

```bash
latchkey run --proxy --env shop/development -- npm test
```

For AWS, `latchkey run --aws-session` (or `--aws-role ARN`) gives the command credentials that expire after 15
minutes instead of your long-lived key. See [short-lived AWS credentials](cli.md#short-lived-aws-credentials).

## After an agent session

See what the agent was given, and replace anything you'd rather it no longer knew:

```bash
latchkey touched --since 4h --by claude
latchkey rotate --touched --since 4h --by claude --open --push
```

## From another Mac over SSH

Forward Latchkey's socket when you connect, then point `latchkey` on the other Mac at it:

```bash
ssh -o StreamLocalBindUnlink=yes -R /tmp/latchkey-$USER.sock:"$HOME/Library/Application Support/Latchkey/broker.sock" devmac
```

```bash
export LATCHKEY_SOCKET=/tmp/latchkey-$USER.sock    # on the other Mac
latchkey run --env shop/development -- npm test
```

Requests reach the app on your Mac, which asks you there. The other computer needs `latchkey` too (a Mac; the tool
is macOS only). What's different:

- **Each read without No Approval asks.** Your Mac sees only your `ssh` client, not the program on the other
  computer, so grants don't apply and can't be made over the connection.
- **The approval panel says so**, and shows what the tool on the other computer says it's running, marked as
  unchecked.
- **The tool there can't check the app's signature** through a forwarded socket; `latchkey status` says so.
- The forwarded socket on the other computer is created owner-only (sshd's default `StreamLocalBindMask`). Anyone
  with your account there can use it while you're connected.

## Latchkey's MCP server

`latchkey mcp` gives agents Latchkey's tools over MCP, for clients without a shell (Claude Desktop) and for
structured refusals instead of exit codes. There is no direct secret-read tool. Child output masks exact values, but transformed secrets can still leak.

```bash
claude mcp add latchkey -- ~/.local/bin/latchkey mcp
```

| Tool | What it does | Asks you? |
|---|---|---|
| `latchkey_status` | Where values are kept, how you approve, item and grant counts | No |
| `latchkey_list` | Item IDs with kind, service and agent-safe, by project or environment. Never values | No |
| `latchkey_check` | What a run would get without asking, what would ask, what's missing | No |
| `latchkey_run` | Runs a command with references filled in, in a given folder, from env files, environments or key files. Returns the exit code and the output, masked | When an item isn't agent-safe or granted |
| `latchkey_request_grant` | Asks you for a grant on items in the agent's folder | Always |
| `latchkey_project` | Which project the folder's checkout is, from its Git remotes, and its environments | No |
| `latchkey_export_references` | Writes an environment's env file of references and plain settings, never values; an existing file only with `replace` | No |

- **Output** is always masked, and only the last 64 KB of each stream is returned. Standard input is empty.
- **Commands stop** after 10 minutes by default, at most 60. Use it for tests, builds and scripts; run dev servers in
  a shell with `latchkey run`.
- **Grants an agent asks for** cover only the folder it runs in (and that repository's worktrees), end when the
  agent quits or after a day at most, and can't include production environments or a whole project. Grant those yourself with `latchkey grant`.
- **Approval panels** for requests through the MCP server say they come from an agent.
- Not offered: reading values, exporting values, changing or deleting items or records, history values, remote
  locations and pushes.

## Other MCP servers

An MCP server started as a command can get its keys through Latchkey. Wrap the command and keep references in its
environment:

```json
{
  "command": "latchkey",
  "args": ["run", "--no-masking", "--", "npx", "-y", "some-mcp-server"],
  "env": { "SOME_API_KEY": "latchkey://SOME_API_KEY" }
}
```

Use `--no-masking`: MCP speaks over standard output, which should pass through untouched. The server's process
chain includes the agent, so make its items agent-safe or grant them. Servers reached over HTTP with a header can't
be wrapped this way.

## Key files

```bash
latchkey run --file ASC_KEY_PATH=shop/production/ASC_P8 -- fastlane beta
```

The command gets the path of a temporary file only you can read, deleted when it exits.

## What Latchkey can't do for you

A value you release to a command is in that command's memory and environment. A command run by an agent can print it
to a file, send it over the network, or encode it so masking doesn't catch it. Masking only hides exact copies (6
characters or longer) in what the command prints. Agent-safe and grants decide what reaches the command; they can't
control what the command does with it. See [Security](security.md).
