# Pistachio

A secrets manager for your Macs and the coding agents that run on them.

Your project files keep references like `pistachio://shop/production/DATABASE_URL`. Pistachio keeps the values in
iCloud Keychain and fills them in when a command starts, so `.env` files stop holding secrets, values follow you
to every Mac you use, and an agent only gets what you've allowed.

```
.env.local                         Pistachio                            your command
DATABASE_URL=pistachio://shop/…  ──► approve (Touch ID) or a grant ──► DATABASE_URL=postgres://…
```

## Command names

Use **`pst`** for short or **`pistachio`** in full. Installers and Homebrew provide both names.
Source builds support `swift run pst` and `swift run pistachio`.

## What it does

- **Keeps values out of files.** `pst run -- npm run dev` swaps every `pistachio://` reference for its value
  as the command starts, and hides those values if the command prints them.
- **Asks before it shares.** Reading an item asks you (Touch ID, Apple Watch or your Mac password) and shows which
  program is asking, from which folder, for which command. You can allow once, allow a folder for a while, or mark
  an item safe for agents to read.
- **Organizes by project.** Items belong to a project's environment (`shop/development`, `shop/vercel.preview`), or
  are shared. Import a `.env` file, or a hundred, and Pistachio places each value for you.
- **Remembers.** Every read and change is logged without values. Earlier values are kept, and a deleted item can
  be restored for 30 days.
- **Pushes where values live.** Link an environment to Vercel, GitHub Actions, Railway, Fly or a credential script
  on a Linux host over ssh, and push to it, using each service's own tool.
- **Syncs.** Values are in iCloud Keychain, end-to-end encrypted, on every Mac signed in to your Apple Account.

## Quick start

```bash
pst import .env.local --dry-run     # see what would be imported; prints names, never values
pst import .env.local --rewrite     # import, then replace each value in the file with its reference
pst run --env-file .env.local -- npm run dev
```

Requires macOS 15 or later. See [Getting started](docs/getting-started.md) to install.

## For coding agents

Pistachio ships a skill that teaches an agent to run commands through `pst` and never handle values, and an MCP
server (`pst mcp`). In Claude Code, the plugin installs both:

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
| [Importing](docs/import.md) | Moving `.env` files into Pistachio, one or many at a time |
| [Remote locations](docs/remote.md) | Vercel, GitHub Actions, Railway, Fly and Linux hosts over ssh |
| [Security](docs/security.md) | What Pistachio protects against, and what it doesn't |
| [Security policy](SECURITY.md) | Reporting a vulnerability |
| [Apple Passwords and passkeys](docs/apple-passwords-and-passkeys.md) | How Pistachio relates to the Passwords app |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and fixes |
| [Development](docs/development.md) | Building, testing and how it fits together |
| [App Store preparation](docs/app-store.md) | Apple SDK boundaries, experimental sandbox build and full-functionality gates |
| [Releasing](docs/releasing.md) | Developer ID signing, notarization and the disk image |
| [Website](docs/site.md) | The product site and developer docs in `site/` |
| [Changelog](CHANGELOG.md) | What changed in each release |

## Repository map

```
Sources/         LatchkeyCore (the library), pistachio (the command-line tool), latchkey-broker (a broker without a window)
Tests/           unit tests for LatchkeyCore
App/             the SwiftUI app, its XcodeGen project and Pistachio for Safari
plugins/         the agent skill and Claude Code plugin
docs/            user and developer documentation
site/            the product website, static HTML
scripts/         install and release scripts
AGENTS.md        the operating contract for coding agents; project intent and records are in .agents/
```

[Development](docs/development.md) describes the layout in full.

## Verification

```bash
swift test                          # unit tests; use in-memory stores, never the real keychain
node --test App/Safari/*.test.js    # the Safari extension's detector and DOM fixtures
```

CI runs `swift test` on pull requests that touch `Sources/`, `Tests/` or `Package.swift`. App compilation and these tests do not replace signed-app,
real-Safari or cross-device sync verification; [Development](docs/development.md#regression-checks) lists what each
check covers and what stays opt-in.

## Status and limitations

Pistachio is pre-1.0; releases are listed in the [changelog](CHANGELOG.md). The command-line tool needs macOS 14
or later and the app needs macOS 15 or later. The Mac App Store build is sandboxed and leaves out GitHub Actions
pushes. [Security](docs/security.md#where-protection-ends) lists what Pistachio does not protect against.

## License

Pistachio is source-available under the [Functional Source License, Version 1.1, ALv2 Future License](LICENSE.md)
(FSL-1.1-ALv2): you may use, change and share it for any purpose except a competing product, and each version
becomes available under the Apache License 2.0 two years after its release. Copyright 2026 Snack Studio.
