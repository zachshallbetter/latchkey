---
name: latchkey
description: >-
  Run commands that need API keys, database URLs or other secrets through Latchkey (`lk`, also `latchkey`)
  instead of reading or writing .env values. Use whenever a task needs credentials (tests, dev servers, migrations,
  deploy scripts, SDK calls), when an env file holds latchkey:// references, when a command fails for a missing
  key, when asked to create or fill in a .env file, or when the user mentions Latchkey.
---

# Latchkey

The person keeps their secrets in Latchkey, on their Mac, in iCloud Keychain. You never see a value, and you never
need to. Env files hold references such as `latchkey://shop/development/DATABASE_URL`; `lk run` fills them in when a
command starts, after the person approves on their Mac or under a grant they made.

## Rules

- Never run `lk get` or `latchkey get`. It prints a value.
- Never print the environment (`env`, `printenv`, `echo $KEY`) of a command started by `lk run`, and never write a
  value into a file, a commit, a log or a message.
- Never put a real value in an env file. Put a reference: `NAME=latchkey://ID`.
- If `lk` exits with **77** (refused) or **66** (missing), stop and tell the person what it printed. Don't retry,
  and don't look for the value elsewhere.

## Running a command that needs secrets

```bash
lk run --env-file .env.local -- npm test          # the file's latchkey:// references are filled in
lk run --env shop/development -- npm run dev      # a whole environment, no file needed
```

Everything after `--` is the command. Its exit status becomes `lk run`'s. Values that the command prints appear as
`<concealed by latchkey>`.

Check first when a run might ask the person, so you can tell them before a slow command waits on an approval:

```bash
lk check --env-file .env.local -- npm test        # agent-safe, granted, will ask, or missing. Asks nothing.
lk list --project shop                            # item IDs and kinds, never values
```

For OpenAI and Anthropic keys, prefer `lk run --proxy`: the command gets a placeholder and a local base URL, and
Latchkey adds the real key only to requests to the provider. It works when the code uses the official SDKs or reads
`OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL`; if the code calls the API at a fixed URL, leave `--proxy` off.

For AWS, `lk run --aws-session` (or `--aws-role ARN`) gives the command 15-minute credentials instead of the
long-lived key.

## In a fresh clone or worktree

The gitignored env file isn't there. Find the project and write one of references from Latchkey's record:

```bash
lk project                                        # which project this checkout is, and its environments
lk export shop/development --out .env.local       # references and plain settings, never values
```

Never use `lk export --values`: it writes secrets to disk and is refused for agents anyway. If `lk export` says there's
no record, `lk run --env shop/development -- …` still works; tell the person `lk env migrate` makes the record.

## Setting up a project's env file

When a project needs an `.env` from `.env.example`, copy it and set each secret to a reference. Shared keys use a bare
name; a project's own keys use `project/environment/NAME`:

```bash
cp .env.example .env
```

```
ANTHROPIC_API_KEY=latchkey://ANTHROPIC_API_KEY
DATABASE_URL=latchkey://shop/development/DATABASE_URL
```

Run `lk list` to find the IDs that exist. If one is missing, give the person the command to add it themselves, and
wait. Don't ask them to paste the value to you:

```bash
lk set ANTHROPIC_API_KEY --kind token --service Anthropic
```

## When the person is away

Reads that aren't agent-safe or granted show an approval panel on their Mac and wait. If they want you to work
unattended, suggest a grant they run themselves, from inside this session so it ends when you do:

```bash
lk grant 'shop/development/*' --session --for 4h
lk grant ANTHROPIC_API_KEY,OPENAI_API_KEY --command "npm test" --for 2h
```

Grants can't cover production items you ask for through MCP, and you shouldn't ask for production in a suggestion
either unless the person brought it up.

## MCP

If the `latchkey` MCP server is connected (`lk mcp`), its tools do the same without a shell: `latchkey_check`,
`latchkey_run` (output masked, last 64 KB), `latchkey_list`, `latchkey_status`, `latchkey_request_grant`,
`latchkey_project` and `latchkey_export_references` (an env file of references for a fresh checkout). They never
return a value.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | Done | |
| 64 | Wrong usage | Fix the command |
| 66 | No item with that ID | Stop; give the person the `lk set` command |
| 69 | The Latchkey app can't be reached | Stop; ask the person to open Latchkey |
| 73 | A file couldn't be rewritten | Stop and report |
| 77 | Refused | Stop; the person denied it or no grant covers it. Show them the `lk grant` line it printed. Don't retry |
| 127 | The command couldn't start | Fix the command |
