# Troubleshooting

## "cannot reach the Pistachio app" (exit 69)

The command-line tool starts the app when it isn't running. If that fails:

- Check the app is installed: `ls /Applications/Latchkey.app`.
- Open it once by hand, then try again.
- If `latchkey-broker` (the development broker) is running, stop it: it uses the same socket.
- `PISTACHIO_NO_LAUNCH=1` is set? Unset it, or start the app yourself.
- `connection refused` or `connection closed` right after installing or updating Pistachio: the app was restarting.
  Run the command again.

## "the program answering on Pistachio's socket isn't the Pistachio app"

`pistachio` checks the app's signature before sending anything. Another program is listening where the app should be:
quit it (the message names it), then open Pistachio. A development build of the app, signed by a different team than
the tool, causes this too; install both from the same build.

## "Asked by a program that isn't Pistachio's command-line tool"

The approval panel shows this when something other than the signed `pistachio` tool asks, such as a script talking
to the socket directly, or an unsigned development build of the tool. Deny it unless you know what it is.

## "refused" (exit 77)

The item isn't agent-safe, nobody approved, and no grant covers it. The message names the items and the grant command
that would allow them. Approve the next request, grant the folder, or mark the item agent-safe if it really isn't
secret. A request nobody answers is denied after two minutes.

## "no item named" (exit 66)

Check the ID with `pst list`. IDs are case-sensitive, and a project item's ID includes its project and
environment (`shop/production/DATABASE_URL`, not `DATABASE_URL`). If you deleted it in the last 30 days, `pistachio
deleted` lists it and `pst restore ID` brings it back.

## Values aren't syncing

`pst status` should say `storage: iCloud Keychain storage (sync status not verified)`.

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

Pistachio runs one copy at a time; opening it again brings the running copy forward. If it was started in the
background by the command-line tool, click its Dock icon or the key in the menu bar.

## An approval panel didn't show up

It appears over whatever app you're in, without bringing Pistachio's window forward. If the screen was locked or nobody
answered for two minutes, the request was denied: run the command again.

## Touch ID in the panel doesn't respond

The fingerprint in the panel turns red when it's listening. For a production push it waits until **I mean to change
production** is ticked. If it still doesn't respond (the sensor is covered, the lid is closed, or too many tries
failed), use **Use Password…**, which opens the system sheet for your Mac password or an Apple Watch.

## A push failed

- `isn't installed`: install the service's tool (`vercel`, `gh`, `railway`, `flyctl`). Pistachio looks in
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, mise shims and `~/.fly/bin`.
- Signed-out or permission errors: sign in to the tool (`vercel login`, `gh auth login`, `railway login`,
  `flyctl auth login`) and check it can reach the project.
- Vercel or Railway "no linked project": link with `project=` or `dir=` pointing at a folder linked with
  `vercel link` / `railway link`.
- Fly: values with line breaks can't be pushed with `secrets import`.
- `pushes run in the Pistachio app`: you're using the development broker; use the app.
- SSH, `sudo: a password is required`: the host needs a sudoers rule that lets your account run the credential script
  without a password; a push has no terminal to type one in. See [SSH credential scripts](remote.md#ssh-credential-scripts).
- SSH, `didn't confirm storing it`: the script exited 0 but didn't print `stored ADAPTER.ACCOUNT`, so Pistachio
  doesn't count it as pushed. Check the script on the host.
- SSH, `isn't a credential name (ADAPTER.ACCOUNT)`: rename the item so its last part is `ADAPTER.ACCOUNT`, for
  example `distribution/production/bluesky.someone.bsky.social`.

## `pst import` skipped some lines

The dry run says why for each: empty, already a reference, an expiring Vercel or Turbo token, a name matched by
`--skip`, an item that already exists (use `--replace`), or a conflict between two files.

## I deleted items, and my `.env` file only has references

Open **Recently Deleted** in the app, or run `pst deleted`, and restore them within 30 days. After that, the
values are gone from Pistachio; check your version control or the service that issued them.

## Pistachio for Safari shows two panels, or Save does nothing

A tab that was open when Pistachio was updated keeps the old extension's script alongside the new one. Reload the tab.
If Save then says it couldn't reach Pistachio, open the app and try again.

## Where are the logs?

The activity log is `~/Library/Application Support/Latchkey/access.jsonl`: one JSON line per read, change, grant,
move, import or push, with the program chain and folder, never values. Settings › **Show in Finder** opens it.
`pistachio log` shows recent entries; `pistachio log --verify` checks that none was changed, removed or added.
