---
name: pistachio
description: >-
  Run commands that need API keys, database URLs or other secrets through Pistachio (`pst`, also `pistachio`; legacy `pst` and `pistachio` remain compatible)
  instead of reading or writing .env values. Use whenever a task needs credentials (tests, dev servers, migrations,
  deploy scripts, SDK calls), when an env file holds pistachio:// references, when a command fails for a missing
  key, when asked to create or fill in a .env file, or when the user mentions Pistachio.
---

# Pistachio

The person keeps their secrets in Pistachio, on their Mac, in iCloud Keychain. You never see a value, and you never
need to. Env files hold references such as `pistachio://shop/development/DATABASE_URL`; `pst run` fills them in when a
command starts, after the person approves on their Mac or under a grant they made.

## Rules

- Never run `pst get` or `pst get`. It prints a value.
- Never print the environment (`env`, `printenv`, `echo $KEY`) of a command started by `pst run`, and never write a
  value into a file, a commit, a log or a message.
- Never put a real value in an env file. Put a reference: `NAME=pistachio://ID`.
- If `pst` exits with **77** (refused) or **66** (missing), stop and tell the person what it printed. Don't retry,
  and don't look for the value elsewhere.

## Running a command that needs secrets

```bash
pst run --env-file .env.local -- npm test          # the file's pistachio:// references are filled in
pst run --env shop/development -- npm run dev      # a whole environment, no file needed
```

Everything after `--` is the command. Its exit status becomes `pst run`'s. Values that the command prints appear as
`<concealed by pistachio>`.

Check first when a run might ask the person, so you can tell them before a slow command waits on an approval:

```bash
pst check --env-file .env.local -- npm test        # agent-safe, granted, will ask, or missing. Asks nothing.
pst list --project shop                            # item IDs and kinds, never values
```

For OpenAI and Anthropic keys, prefer `pst run --proxy`: the command gets a placeholder and a local base URL, and
Pistachio adds the real key only to requests to the provider. It works when the code uses the official SDKs or reads
`OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL`; if the code calls the API at a fixed URL, leave `--proxy` off.

For AWS, `pst run --aws-session` (or `--aws-role ARN`) gives the command 15-minute credentials instead of the
long-lived key.

## In a fresh clone or worktree

The gitignored env file isn't there. Find the project and write one of references from Pistachio's record:

```bash
pst project                                        # which project this checkout is, and its environments
pst export shop/development --out .env.local       # references and plain settings, never values
```

Never use `pst export --values`: it writes secrets to disk and is refused for agents anyway. If `pst export` says there's
no record, `pst run --env shop/development -- …` still works; tell the person `pst env migrate` makes the record.

## Setting up a project's env file

When a project needs an `.env` from `.env.example`, copy it and set each secret to a reference. Shared keys use a bare
name; a project's own keys use `project/environment/NAME`:

```bash
cp .env.example .env
```

```
ANTHROPIC_API_KEY=pistachio://ANTHROPIC_API_KEY
DATABASE_URL=pistachio://shop/development/DATABASE_URL
```

Run `pst list` to find the IDs that exist. If one is missing, give the person the command to add it themselves, and
wait. Don't ask them to paste the value to you:

```bash
pst set ANTHROPIC_API_KEY --kind token --service Anthropic
```

## When the person is away

Reads that aren't agent-safe or granted show an approval panel on their Mac and wait. If they want you to work
unattended, suggest a grant they run themselves, from inside this session so it ends when you do:

```bash
pst grant 'shop/development/*' --session --for 4h
pst grant ANTHROPIC_API_KEY,OPENAI_API_KEY --command "npm test" --for 2h
```

Grants can't cover production items you ask for through MCP, and you shouldn't ask for production in a suggestion
either unless the person brought it up.

## MCP

If the `pistachio` MCP server is connected (`pst mcp`), its tools do the same without a shell: `pistachio_check`,
`pistachio_run` (output masked, last 64 KB), `pistachio_list`, `pistachio_status`, `pistachio_request_grant`,
`pistachio_project` and `pistachio_export_references` (an env file of references for a fresh checkout). They never
return a value.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | Done | |
| 64 | Wrong usage | Fix the command |
| 66 | No item with that ID | Stop; give the person the `pst set` command |
| 69 | The Pistachio app can't be reached | Stop; ask the person to open Pistachio |
| 73 | A file couldn't be rewritten | Stop and report |
| 77 | Refused | Stop; the person denied it or no grant covers it. Show them the `pst grant` line it printed. Don't retry |
| 127 | The command couldn't start | Fix the command |
