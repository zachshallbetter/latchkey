# Using with agents

Coding agents need your API keys and database URLs to run tests and dev servers. With Pistachio they get them through
`pst run`: the values reach the command, not the agent's files, and you decide which values an agent may use
without asking.

## The pattern

1. Keep references in your env files (`pst import .env.local --rewrite` does this).
2. Run anything that needs secrets through `pst run`:

   ```bash
   pst run --env-file .env.local -- npm test
   pst run --env shop/development -- npm run dev       # no env file needed
   ```

3. Decide what an agent may read without you:
   - **Agent-safe** items, for values that aren't really secret.
   - **Grants**, for a folder and a time: `pst grant 'shop/development/*' --folder ~/Projects/shop --for 2h`.
   - Everything else asks you, with the agent's process chain, folder and command shown.

Fresh git worktrees and clones don't have your `.env` (it's gitignored). `pst project` says which project the
checkout is; `pst export PROJECT/ENV --out .env.local` writes an env file of references from the environment's
record, with no values in it; `pst run --env PROJECT/ENV` loads the environment without any file. A grant for a
repository's folder covers its worktrees.

## Skills and plugins

The Pistachio skill (`plugins/latchkey/skills/latchkey/SKILL.md`) tells an agent everything below: run commands
through `pst run`, check before a slow run, never print or write a value, put references in env files, give the
person the `pst set` command for a missing key, suggest a session grant when they step away, and stop on 77 or 66.

- **Claude Code:** the plugin installs the skill and registers `pst mcp` as an MCP server.

  ```
  /plugin install latchkey --marketplace zachshallbetter/latchkey
  ```

  The MCP server is started as `pst`, so `~/.local/bin` must be on the `PATH` Claude Code starts with.
- **Codex CLI, Gemini CLI, Cursor and other tools that read the Agent Skills format:** copy the
  `plugins/latchkey/skills/latchkey` folder into the skills folder your tool reads (for example, `.agents/skills/`
  in a project for Codex).
- **Claude Desktop and other MCP clients without a shell:** add `pst mcp` as a local MCP server (see
  [Pistachio's MCP server](#pistachios-mcp-server)). Chat apps that only reach MCP servers on the internet can't use
  Pistachio: its MCP server runs on your Mac.

The direct download's welcome window (and Settings › About › **Show Welcome Again…**) does this for you: **Add**
next to an agent registers `pst mcp` with the full path of the `pst` link (or the tool inside the app) in:

| Agent | MCP server | Skill |
|---|---|---|
| Claude Code | `claude mcp add --scope user pistachio -- <pst> mcp`, run by the app | `~/.claude/skills/pistachio/SKILL.md` |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | — |
| Codex | `[mcp_servers.pistachio]` in `~/.codex/config.toml` | `~/.codex/skills/pistachio/SKILL.md` |
| Cursor | `~/.cursor/mcp.json` | — |
| Gemini CLI | `~/.gemini/settings.json` | — |

Other servers and settings in those files stay as they are, the first change keeps the original beside it as
`<file>.before-pistachio`, and a file that isn't plain JSON (comments, for example) is left alone and reported. Only
agents whose folder exists on the Mac are listed. If `claude` isn't found, the welcome shows the command to run.

The marketplace install works once the repository is public; until then, add the plugin from a local checkout
(`/plugin marketplace add /path/to/pistachio`).

## Instructions to give an agent

Without the skill, put something like this in your agent instructions (`CLAUDE.md`, `AGENTS.md` or similar):

> Secrets are in Pistachio. Env files hold `pistachio://` references, not values. Run anything that needs secrets as
> `pst run --env-file .env.local -- <command>` or `pst run --env <project>/<environment> -- <command>`.
> Never run `pst get`, never print the environment, and never read or write values in `.env` files. If
> `pistachio` exits with 77 (refused) or 66 (missing), stop and ask; don't retry.

## Exit codes

| Code | Meaning | What an agent should do |
|---|---|---|
| 0 | Done | |
| 64 | Wrong usage | Fix the command |
| 66 | No item with that ID | Stop; ask the person to add it |
| 69 | The Pistachio app can't be reached | Stop; ask the person to open Pistachio |
| 73 | A file couldn't be rewritten | Stop and report |
| 77 | Refused: not agent-safe, not approved, no grant | Stop; ask the person to approve or grant. Don't retry |
| 127 | The command couldn't start | Fix the command |

On 77 and 66, Pistachio prints the item IDs and, for 77, the exact `pst grant` command that would allow them.

## Leaving an agent working

Before you step away, grant what the job needs, as narrowly as it allows. Run these inside the agent's session (in
Claude Code, start the line with `!`) so `--session` ties to the agent:

```bash
pst grant 'shop/development/*' --session --for 4h                    # ends when the agent quits
pst grant 'shop/development/*' --command "npm test" --for 2h         # only this command
pst grant 'shop/development/*' --folder ~/Projects/shop --for 2h     # the folder, for a time
```

The agent's reads go through without asking until the grant ends, and each one is in Activity. Revoke it early from
**Grants** in the app or with `pst revoke ID`.

## Keys an agent can use but never read

For OpenAI and Anthropic keys, `pst run --proxy` gives the command a placeholder and a local base URL, and adds
the real key only to requests to the provider. An agent's command can call the API, but can't print, encode or send
the key anywhere else. See [`--proxy`](cli.md#keys-that-never-reach-the-command---proxy).

```bash
pst run --proxy --env shop/development -- npm test
```

For AWS, `pst run --aws-session` (or `--aws-role ARN`) gives the command credentials that expire after 15
minutes instead of your long-lived key. See [short-lived AWS credentials](cli.md#short-lived-aws-credentials).

## After an agent session

See what the agent was given, and replace anything you'd rather it no longer knew:

```bash
pst touched --since 4h --by claude
pst rotate --touched --since 4h --by claude --open --push
```

## From another Mac over SSH

Forward Pistachio's socket when you connect, then point `pistachio` on the other Mac at it:

```bash
ssh -o StreamLocalBindUnlink=yes -R /tmp/pistachio-$USER.sock:"$HOME/Library/Application Support/Latchkey/broker.sock" devmac
```

```bash
export PISTACHIO_SOCKET=/tmp/pistachio-$USER.sock    # on the other Mac
pst run --env shop/development -- npm test
```

`$USER` expands to your login name on each Mac: use the same name on both, or put a fixed name in both commands.
Forwarding needs the direct-download app on your Mac; the Mac App Store version doesn't support it yet, and if the
other Mac has the App Store version installed, set `PISTACHIO_BROKER=direct` there.

Requests reach the app on your Mac, which asks you there. The other computer needs `pistachio` too (a Mac; the tool
is macOS only). What's different:

- **Each read without No Approval asks.** Your Mac sees only your `ssh` client, not the program on the other
  computer, so grants don't apply and can't be made over the connection.
- **The approval panel says so**, and shows what the tool on the other computer says it's running, marked as
  unchecked.
- **The tool there can't check the app's signature** through a forwarded socket; `pst status` says so.
- The forwarded socket on the other computer is created owner-only (sshd's default `StreamLocalBindMask`). Anyone
  with your account there can use it while you're connected.

## Pistachio's MCP server

`pst mcp` gives agents Pistachio's tools over MCP, for clients without a shell (Claude Desktop) and for
structured refusals instead of exit codes. There is no direct secret-read tool. Child output masks exact values, but transformed secrets can still leak.

```bash
claude mcp add pistachio -- ~/.local/bin/pst mcp
```

| Tool | What it does | Asks you? |
|---|---|---|
| `pistachio_status` | Where values are kept, how you approve, item and grant counts | No |
| `pistachio_list` | Item IDs with kind, service and agent-safe, by project or environment. Never values | No |
| `pistachio_check` | What a run would get without asking, what would ask, what's missing | No |
| `pistachio_run` | Runs a command with references filled in, in a given folder, from env files, environments or key files. Returns the exit code and the output, masked | When an item isn't agent-safe or granted |
| `pistachio_request_grant` | Asks you for a grant on items in the agent's folder | Always |
| `pistachio_project` | Which project the folder's checkout is, from its Git remotes, and its environments | No |
| `pistachio_export_references` | Writes an environment's env file of references and plain settings, never values, inside the tool's `cwd` only, and that `cwd` must be the folder the server started in, inside it, or a worktree of its repository; an existing file only with `replace` | No |

The tools were named `pistachio_status`, `pistachio_run` and so on. The old names still work, listed beside the new ones,
until the next release.

- **Output** is always masked, and only the last 64 KB of each stream is returned. Standard input is empty.
- **Commands stop** after 10 minutes by default, at most 60. Use it for tests, builds and scripts; run dev servers in
  a shell with `pst run`.
- **Grants an agent asks for** cover only the folder it runs in (and that repository's worktrees), last for the time
  it asked for (`always` for no time limit), which you see in the panel and approve, and end when the agent quits.
  They can't include production environments or a whole project. Grant those yourself with `pst grant`.
- **Approval panels** for requests through the MCP server say they come from an agent.
- **Several requests in a row** from the same agent in the same folder share one panel while it's up, and one touch
  answers them; a grant ("until the agent quits") stops the asking for the rest of the session.
- Not offered: reading values, exporting values, changing or deleting items or records, history values, remote
  locations and pushes.

## Other MCP servers

An MCP server started as a command can get its keys through Pistachio. Wrap the command and keep references in its
environment:

```json
{
  "command": "pistachio",
  "args": ["run", "--no-masking", "--", "npx", "-y", "some-mcp-server"],
  "env": { "SOME_API_KEY": "pistachio://SOME_API_KEY" }
}
```

Use `--no-masking`: MCP speaks over standard output, which should pass through untouched. The server's process
chain includes the agent, so make its items agent-safe or grant them. Servers reached over HTTP with a header can't
be wrapped this way.

## Key files

```bash
pst run --file ASC_KEY_PATH=shop/production/ASC_P8 -- fastlane beta
```

The command gets the path of a temporary file only you can read, deleted when it exits.

## What Pistachio can't do for you

A value you release to a command is in that command's memory and environment. A command run by an agent can print it
to a file, send it over the network, or encode it so masking doesn't catch it. Masking only hides exact copies (6
characters or longer) in what the command prints. Agent-safe and grants decide what reaches the command; they can't
control what the command does with it. See [Security](security.md).
