# Troubleshooting

## "cannot reach the Latchkey app" (exit 69)

The command-line tool starts the app when it isn't running. If that fails:

- Check the app is installed: `ls /Applications/Latchkey.app`.
- Open it once by hand, then try again.
- If `latchkey-broker` (the development broker) is running, stop it: it uses the same socket.
- `LATCHKEY_NO_LAUNCH=1` is set? Unset it, or start the app yourself.

## "the program answering on Latchkey's socket isn't the Latchkey app"

`latchkey` checks the app's signature before sending anything. Another program is listening where the app should be:
quit it (the message names it), then open Latchkey. A development build of the app, signed by a different team than
the tool, causes this too; install both from the same build.

## "Asked by a program that isn't Latchkey's command-line tool"

The approval panel shows this when something other than the signed `latchkey` tool asks, such as a script talking
to the socket directly, or an unsigned development build of the tool. Deny it unless you know what it is.

## "refused" (exit 77)

The item isn't agent-safe, nobody approved, and no grant covers it. The message names the items and the grant command
that would allow them. Approve the next request, grant the folder, or mark the item agent-safe if it really isn't
secret. An approval panel nobody answers counts as a denial after 90 seconds.

## "no item named" (exit 66)

Check the ID with `latchkey list`. IDs are case-sensitive, and a project item's ID includes its project and
environment (`shop/production/DATABASE_URL`, not `DATABASE_URL`). If you deleted it in the last 30 days, `latchkey
deleted` lists it and `latchkey restore ID` brings it back.

## Values aren't syncing

`latchkey status` should say `storage: iCloud Keychain (synced to your Macs)`.

- **It says "login keychain on this Mac only"**: the app isn't signed with a developer team. Set `DEVELOPMENT_TEAM`
  in `App/project.yml` and run `scripts/install.sh` again ([Getting started](getting-started.md#install-from-source)).
  Then open Settings and use **Move to iCloud Keychain** for items saved before.
- **Turn on iCloud Keychain**: System Settings › your name › iCloud › Passwords & Keychain.
- **Same team everywhere**: every Mac needs a build signed by the same team. A build signed by another team can't see
  the items.
- iCloud Keychain can take a few minutes to sync a change.

## macOS asks for my login password to use an item

That's the login keychain protecting items saved by a different build. It happens with unsigned builds, where every
rebuild is a new identity. Choose **Always Allow**, or sign the app with your team so items live in iCloud Keychain.

## The window doesn't appear

Latchkey runs one copy at a time; opening it again brings the running copy forward. If it was started in the
background by the command-line tool, click its Dock icon or the key in the menu bar.

## An approval panel didn't show up

Check for it behind other windows; it floats above most of them. If the screen was locked or nobody answered for 90
seconds, the request was denied: run the command again.

## A push failed

- `isn't installed`: install the service's tool (`vercel`, `gh`, `railway`, `flyctl`). Latchkey looks in
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, mise shims and `~/.fly/bin`.
- Signed-out or permission errors: sign in to the tool (`vercel login`, `gh auth login`, `railway login`,
  `flyctl auth login`) and check it can reach the project.
- Vercel or Railway "no linked project": link with `project=` or `dir=` pointing at a folder linked with
  `vercel link` / `railway link`.
- Fly: values with line breaks can't be pushed with `secrets import`.
- `pushes run in the Latchkey app`: you're using the development broker; use the app.

## `latchkey import` skipped some lines

The dry run says why for each: empty, already a reference, an expiring Vercel or Turbo token, a name matched by
`--skip`, an item that already exists (use `--replace`), or a conflict between two files.

## I deleted items, and my `.env` file only has references

Open **Recently Deleted** in the app, or run `latchkey deleted`, and restore them within 30 days. After that, the
values are gone from Latchkey; check your version control or the service that issued them.

## Where are the logs?

The activity log is `~/Library/Application Support/Latchkey/access.jsonl`: one JSON line per read, change, grant,
move, import or push, with the program chain and folder, never values. Settings › **Show in Finder** opens it.
`latchkey log` shows recent entries; `latchkey log --verify` checks that none was changed, removed or added.
