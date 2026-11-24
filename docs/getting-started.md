# Getting started

## Requirements

- macOS 15 or later.
- iCloud Keychain turned on (System Settings › your name › iCloud › Passwords & Keychain) if you want values on
  more than one Mac.
- To build from source: Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
  xcodegen`), and an Apple Account signed in to Xcode.

## Install a release

Download the latest disk image from [Releases](https://github.com/zachshallbetter/latchkey/releases/latest), or install with Homebrew:

```bash
brew tap zachshallbetter/latchkey
brew trust zachshallbetter/latchkey
brew install --cask latchkey
```

Homebrew asks you to trust a tap before installing from it. With the disk image:

1. Open the disk image and drag the app to **Applications**.
2. Open Pistachio from Applications.
3. Choose **Install Command Line Tool…** in the app menu (also in Settings). It links `~/.local/bin/pistachio`, and `pst`
   for short, to the copy inside the app, so it updates when the app does. Make sure `~/.local/bin` is on your `PATH`.
4. Check it:

   ```bash
   pst status
   ```

   You should see `storage: iCloud Keychain storage (sync status not verified)`.

Install it the same way on each Mac signed in to your Apple Account; items sync between them.

## Install from source

Pistachio keeps values in iCloud Keychain, which macOS only opens to apps signed with a developer team. So the build
needs your team:

1. In Xcode, open **Settings › Accounts** and sign in with your Apple Account. A free personal team works.
2. Clone the repository and open `App/project.yml`. Set `DEVELOPMENT_TEAM` to your team ID. (To find it, run
   `cd App && xcodegen && open Latchkey.xcodeproj`, choose your team under **Signing & Capabilities**, and copy the
   ID Xcode writes into the project.)
3. From the repository's folder, run:

   ```bash
   scripts/install.sh
   ```

   It builds the command-line tool and the app, installs `/Applications/Latchkey.app` and `~/.local/bin/pistachio` (and `pst`),
   and starts the app. Make sure `~/.local/bin` is on your `PATH` (the script says so if it isn't).

4. Check it:

   ```bash
   pst status
   ```

   `storage: iCloud Keychain storage (sync status not verified)` means you're set. `login keychain on this Mac only` means the
   app isn't signed with a team; see [Troubleshooting](troubleshooting.md#values-arent-syncing).

On each other Mac, sign in to Xcode with the same Apple Account and run `scripts/install.sh`. Every Mac must use a
build signed by the same team, or they can't see each other's items.

Pistachio runs one copy at a time. The command-line tool starts the app in the background when it isn't running;
turn on **Open Pistachio at login** in Settings to skip that wait.

## Your first item

Pistachio opens locked; touch the sensor, or use your Mac password, to unlock it ([Locking](app.md#locking)). In the
app, click **+ › New Item…**, or on the command line:

```bash
pst set GEMINI_API_KEY --kind token
```

You're prompted for the value; it isn't shown. Saving asks for Touch ID. `GEMINI_API_KEY` is a shared item: one
value, usable from any project. Items that belong to a project look like `shop/production/DATABASE_URL`; see
[Concepts](concepts.md#items-and-ids).

## Your first command

Put a reference in a file, or in your environment:

```bash
echo 'GEMINI_API_KEY=pistachio://GEMINI_API_KEY' > .env.local
pst run --env-file .env.local -- node script.js
```

Pistachio asks before it releases the value (the panel shows the program, folder and command), then starts
`node script.js` with the real value. If the command prints the value, it appears as a concealment marker.

## Your first import

Most projects already have a `.env` file full of values. Move them in:

```bash
cd ~/Projects/shop
pst import .env.local --dry-run
pst import .env.local --rewrite
```

The dry run lists what would happen: the project (`shop`, from the repository's folder), the environment
(`development`, from the file name) and each item's ID, never the values. `--rewrite` imports with one approval,
then replaces each value in the file with its `pistachio://` reference. The file is now safe to keep around.

Have many projects? `pst import --scan ~/Projects --dry-run` finds every env file and shows where each value
would go; run it without `--dry-run` (and with `--rewrite`) to bring them all in with one approval. See
[Importing](import.md).

## Uninstall

1. If you want your items gone too, delete them first: they're in iCloud Keychain, not in the app, and stay there
   (synced to your other Macs) after the app is removed. In the window, select them, **Delete…**, then in
   **Recently Deleted** use **Forget for Good…** on each. Remove remote links with **Remote Locations…** › **Unlink…**,
   or `pst remote unlink`.
2. Turn off **Open at login** in Settings.
3. Quit Pistachio from the menu bar icon › **Quit**.
4. Remove the app, the command-line tool, its folder and its settings:

   ```bash
   rm -rf /Applications/Latchkey.app
   ```

   ```bash
   rm -f ~/.local/bin/pistachio ~/.local/bin/pst ~/.local/bin/pistachio
   ```

   ```bash
   rm -rf ~/Library/Application\ Support/Pistachio
   ```

   ```bash
   defaults delete io.snackstud.latchkey
   ```

   The folder holds the access log and the broker socket.

Items retained in iCloud Keychain return when you install the app again with the same Apple Account.
To remove them permanently, delete them in the app before uninstalling, or remove the app’s items in Keychain Access.

## Next

- [Using with agents](agents.md): let a coding agent run your project without holding your secrets.
- [The app](app.md): find, organize and review your items.
- [Security](security.md): what Pistachio protects against.
