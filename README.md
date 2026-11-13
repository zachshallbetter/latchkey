# Latchkey

A secrets manager for your Macs and the coding agents that run on them.

Your project files keep references like `latchkey://shop/production/DATABASE_URL`. Latchkey keeps the values in
iCloud Keychain and fills them in when a command starts, so `.env` files stop holding secrets, values follow you
to every Mac you use, and an agent only gets what you've allowed.

```
.env.local                         Latchkey                            your command
DATABASE_URL=latchkey://shop/…  ──► approve (Touch ID) or a grant ──► DATABASE_URL=postgres://…
```

## What it does

- **Keeps values out of files.** `latchkey run -- npm run dev` swaps every `latchkey://` reference for its value
  as the command starts, and hides those values if the command prints them.
- **Asks before it shares.** Reading an item asks you (Touch ID, Apple Watch or your Mac password) and shows which
  program is asking, from which folder, for which command. You can allow once, allow a folder for a while, or mark
  an item safe for agents to read.
- **Organizes by project.** Items belong to a project's environment (`shop/development`, `shop/vercel.preview`), or
  are shared. Import a `.env` file, or a hundred, and Latchkey places each value for you.
- **Remembers.** Every read and change is logged without values. Earlier values are kept, and a deleted item can
  be restored for 30 days.
- **Pushes where values live.** Link an environment to Vercel, GitHub Actions, Railway or Fly and push to it, using
  each service's own tool.
- **Syncs.** Values are in iCloud Keychain, end-to-end encrypted, on every Mac signed in to your Apple Account.

## Quick start

```bash
latchkey import .env.local --dry-run     # see what would be imported; prints names, never values
latchkey import .env.local --rewrite     # import, then replace each value in the file with its reference
latchkey run --env-file .env.local -- npm run dev
```

Requires macOS 15 or later. See [Getting started](docs/getting-started.md) to install.

## For coding agents

Latchkey ships a skill that teaches an agent to run commands through `lk` and never handle values, and an MCP
server (`lk mcp`). In Claude Code, the plugin installs both:

```
/plugin install latchkey --marketplace zachshallbetter/latchkey
```

Codex CLI, Gemini CLI, Cursor and other tools that read Agent Skills can use the skill folder directly:
`plugins/latchkey/skills/latchkey`. See [Using with agents](docs/agents.md#skills-and-plugins).

## Documentation

| | |
|---|---|
| [Getting started](docs/getting-started.md) | Install, first item, first command, first import, uninstall |
| [Concepts](docs/concepts.md) | Items and IDs, projects and environments, approvals, grants, history, sync |
| [The app](docs/app.md) | The window, the menu bar, approvals and settings |
| [Command line](docs/cli.md) | Every command and option, and exit codes |
| [Using with agents](docs/agents.md) | Running agents with secrets they can use but don't hold |
| [Importing](docs/import.md) | Moving `.env` files into Latchkey, one or many at a time |
| [Remote locations](docs/remote.md) | Vercel, GitHub Actions, Railway and Fly |
| [Security](docs/security.md) | What Latchkey protects against, and what it doesn't |
| [Security policy](SECURITY.md) | Reporting a vulnerability |
| [Apple Passwords and passkeys](docs/apple-passwords-and-passkeys.md) | How Latchkey relates to the Passwords app |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and fixes |
| [Development](docs/development.md) | Building, testing and how it fits together |
| [App Store preparation](docs/app-store.md) | Apple SDK boundaries, experimental sandbox build and full-functionality gates |
| [Releasing](docs/releasing.md) | Developer ID signing, notarization and the disk image |
| [Website](docs/site.md) | The product site and developer docs in `site/` |
| [Changelog](CHANGELOG.md) | What changed in each release |


## License

Latchkey is source-available under the [Functional Source License, Version 1.1, ALv2 Future License](LICENSE.md)
(FSL-1.1-ALv2): you may use, change and share it for any purpose except a competing product, and each version
becomes available under the Apache License 2.0 two years after its release. Copyright 2026 Snack Studio.
