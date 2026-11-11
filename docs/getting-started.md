# Getting started

## Requirements

- macOS 15 or later.
- iCloud Keychain turned on (System Settings › your name › iCloud › Passwords & Keychain) if you want values on
  more than one Mac.
- To build from source: Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
  xcodegen`), and an Apple Account signed in to Xcode.

## Install from source

Latchkey keeps values in iCloud Keychain, which macOS only opens to apps signed with a developer team. So the build
needs your team:

1. In Xcode, open **Settings › Accounts** and sign in with your Apple Account. A free personal team works.
2. Clone the repository and open `App/project.yml`. Set `DEVELOPMENT_TEAM` to your team ID. (To find it, run
   `cd App && xcodegen && open Latchkey.xcodeproj`, choose your team under **Signing & Capabilities**, and copy the
   ID Xcode writes into the project.)
3. From the repository's folder, run:

   ```bash
   scripts/install.sh
   ```

   It builds the command-line tool and the app, installs `/Applications/Latchkey.app` and `~/.local/bin/latchkey`,
   and starts the app. Make sure `~/.local/bin` is on your `PATH` (the script says so if it isn't).

4. Check it:

   ```bash
   latchkey status
   ```

   `storage: iCloud Keychain (synced to your Macs)` means you're set. `login keychain on this Mac only` means the
   app isn't signed with a team; see [Troubleshooting](troubleshooting.md#values-arent-syncing).

On each other Mac, sign in to Xcode with the same Apple Account and run `scripts/install.sh`. Every Mac must use a
build signed by the same team, or they can't see each other's items.

Latchkey runs one copy at a time. The command-line tool starts the app in the background when it isn't running;
turn on **Open Latchkey at login** in Settings to skip that wait.

## Your first item

In the app, click **+ › New Item…**, or on the command line:

```bash
latchkey set GEMINI_API_KEY --kind token
```

You're prompted for the value; it isn't shown. Saving asks for Touch ID. `GEMINI_API_KEY` is a shared item: one
value, usable from any project. Items that belong to a project look like `shop/production/DATABASE_URL`; see
[Concepts](concepts.md#items-and-ids).

## Your first command

Put a reference in a file, or in your environment:

```bash
echo 'GEMINI_API_KEY=latchkey://GEMINI_API_KEY' > .env.local
latchkey run --env-file .env.local -- node script.js
```

Latchkey asks before it releases the value (the panel shows the program, folder and command), then starts
`node script.js` with the real value. If the command prints the value, it appears as `<concealed by latchkey>`.

## Your first import

Most projects already have a `.env` file full of values. Move them in:

```bash
cd ~/Projects/shop
latchkey import .env.local --dry-run
latchkey import .env.local --rewrite
```

The dry run lists what would happen: the project (`shop`, from the repository's folder), the environment
(`development`, from the file name) and each item's ID, never the values. `--rewrite` imports with one approval,
then replaces each value in the file with its `latchkey://` reference. The file is now safe to keep around.

Have many projects? `latchkey import --batch` takes a list of files and imports them all with one approval. See
[Importing](import.md).

## Next

- [Using with agents](agents.md): let a coding agent run your project without holding your secrets.
- [The app](app.md): find, organize and review your items.
- [Security](security.md): what Latchkey protects against.
