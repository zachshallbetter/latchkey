# Installer

Latchkey's direct download ships as a signed, notarized installer package (`Latchkey-VERSION.pkg`), the recommended
download, next to the disk image (`Latchkey-VERSION.dmg`) used for drag installs, Sparkle updates and the Homebrew
cask. The package installs Latchkey, links the command-line tool for the person installing it, and opens Latchkey's
welcome, which shows what's installed and walks through the choices only that person can make. The Mac App Store
version has neither: the App Store installs and updates it.

## What the person sees

1. **Installer, Welcome** (`packaging/pkg/resources/en.lproj/welcome.html`): what Latchkey does and what happens
   next, with the key in the window's lower-left corner (`background.png`, `background-dark.png`, drawn by
   `scripts/make-installer-art.swift`). A Mac older than the deployment target in `App/project.yml` (macOS 15) is
   told before this screen. Installer draws these pages with a basic HTML renderer (no grid or flex, cell widths
   ignored, a block background shades each line, and all text white in dark mode), so they stay plain: headings,
   paragraphs and lists.
2. If Latchkey is running, the Installer asks to quit it first, so it is never replaced while it holds the broker
   socket or an approval is waiting.
3. **Install:** one administrator password.
4. **Installer, Summary** (`conclusion.html`): what's done, the optional steps, and `latchkey status` to check.
5. When the Installer closes, Latchkey opens its **welcome** (`App/Latchkey/Welcome.swift`), even if it was set up
   before:
   - **Installed:** checked live each time the window opens or Latchkey comes back to the front: Latchkey in
     Applications; `latchkey` and `lk` linked in `~/.local/bin` and that folder on the `PATH` a new Terminal window
     gets (read from the login shell, with a Copy line for `~/.zprofile` or `~/.bash_profile` when it isn't, and an
     **Install Command Line Tool** button when the links are missing); iCloud Keychain on, from the same state as the
     sidebar's storage badge.
   - **Optional: Latchkey for Safari:** what it does, its switch as Safari reports it, and **Open Safari Settings**,
     which opens Safari's Extensions settings at Latchkey. Turning it on stays the person's choice.
   - **Optional: connect a coding agent:** `claude mcp add latchkey -- ~/.local/bin/latchkey mcp` with **Copy**, and
     a pointer for other agents.
   - **Last step: a first .env file:** **Choose a .env File…** closes the welcome and opens the usual import sheet in
     the main window, where every line is reviewed before anything is saved.

   The same window opens on the first launch of a copy with no items (a drag install, or Homebrew), from **Settings
   › About & Updates › Show Welcome…** and from **Help › Welcome to Latchkey**. Someone updating from a version
   without it who already has items isn't shown it.

## What runs, and as whom

| Step | Runs as | Where |
| --- | --- | --- |
| Distribution checks (macOS 15 or later, quit a running Latchkey) | Installer | `packaging/pkg/Distribution.xml` |
| Copy `Latchkey.app` to `/Applications` (not relocatable) | Installer | component package |
| `postinstall`: set the app's owner (below), verify the app's signature, start the setup helper as the user at the screen | root | `packaging/pkg/scripts/postinstall` |
| Setup helper (below) | the logged-in user | `Latchkey.app/Contents/Resources/latchkey-setup.sh`, from `packaging/pkg/latchkey-setup.sh` |
| Linking `latchkey` and `lk` | the logged-in user | `Latchkey --install-command-line-tool`, the same code as **Install Command Line Tool…** (`CommandLineToolLinks` in LatchkeyCore) |

**Who owns the app.** `postinstall` sets the owner so Sparkle can update Latchkey without an administrator password,
and makes the bundle group-writable for `admin`:

| Install | Owner | Why |
| --- | --- | --- |
| Installer app, someone at the screen | that user, group `admin` | Like a drag install by that user: their Sparkle updates without a password, and so does any administrator's |
| Command line or MDM (`COMMAND_LINE_INSTALL` set), or nobody at the screen | `root`, group `admin` | A shared copy isn't handed to whoever happens to be logged in. Any administrator's Sparkle updates it; a standard user's asks for an administrator |

A failed `chown` or `chmod` leaves Installer's ownership and doesn't fail the install. With nobody at the screen,
`postinstall` stops after this; the welcome's **Install Command Line Tool** button, or the menu item, links the tool
later.

**The helper never runs from a shared folder.** It is inside the signed app, `postinstall` checks `codesign --verify
--strict` on the app before starting it, and it runs as the user at the screen through `launchctl asuser` and `sudo
-u`, never as root (it refuses to). Nothing is copied to `/tmp` or any other folder another user could write first.

The setup helper, `latchkey-setup.sh [--open] [--app path]`:

1. **Links the command-line tool** by running the app with `--install-command-line-tool`, which exits before any
   window, the broker or the updater starts. It links `~/.local/bin/latchkey` and `~/.local/bin/lk` to
   `Latchkey.app/Contents/Helpers/latchkey`, replacing only links (an older copy's, a disk image's) and leaving a
   file of either name alone; the log says which.
2. **Unregisters other copies** of `io.snackstud.latchkey` with `lsregister -u` (a mounted disk image, Downloads, an
   old install, build folders), so Safari's extension and `open` use the copy in `/Applications`. Their files are
   never touched, and nothing is removed from PluginKit: `pluginkit -r` on another copy's extension, which shares
   Latchkey's identifiers, could reset the person's own Safari switch.
3. **Logs the Safari extension's state** (`pluginkit -m`, read only). It never turns it on or off.
4. With `--open`: waits for the Installer to close (it keeps focus while open), then opens Latchkey with
   `-LatchkeyWelcome YES`, which shows the welcome for that launch only. Command-line and MDM installs
   (`COMMAND_LINE_INSTALL`) link and unregister but don't open anything.

It logs to `~/Library/Logs/Latchkey/setup.log`. Neither script changes System Settings, Safari's settings, any
extension's switch or the keychain.

### Compared with Peel's installer

Latchkey's flow follows Snack Studio's Peel: the same Distribution gate and must-close, plain HTML pages with corner
art in light and dark, the same `postinstall` ownership rule, the helper inside the signed app after `codesign
--verify`, `lsregister -u` only for duplicates, the welcome opened only for an Installer-app install, and tests that
run the scripts' decisions against stubs. What differs:

- Latchkey has no file system or Quick Look extension to register, so the helper doesn't call `lsregister -f`: macOS
  registers the installed copy itself, and Safari finds the extension from it.
- The helper's one change in the person's home folder is the command-line links, made by the app's own code rather
  than a second implementation in shell.
- The Homebrew cask stays on the disk image (`app` and `binary` stanzas): Homebrew links `latchkey` and `lk` into its
  own `bin`, so a root `postinstall` would add nothing for brew users.

## The disk image

`Latchkey-VERSION.dmg` stays for people who prefer to drag, for Sparkle updates (the appcast's enclosure is the disk
image, signed with the EdDSA key) and for the Homebrew cask. `scripts/make-dmg.sh` builds it with dmgbuild
(`packaging/dmg/settings.py`, pinned in a private virtual environment under `build/`), which writes the window layout
into the image without opening Finder: a 640×400 window on a blue background (`packaging/dmg/background.tiff`, from
`scripts/make-installer-art.swift`) with "Secrets out of .env files.", Latchkey and an Applications link either side
of an arrow at 128-point icons, and a line saying the welcome sets up the rest. The blue (`#2D74D3`) is the mid-tone
where Finder's black (light mode) and white (dark mode) icon labels both reach 4.5:1 contrast.

A drag install doesn't run the setup helper, so the welcome's live checks, and its **Install Command Line Tool**
button, cover it.

## Building

```bash
swift scripts/make-installer-art.swift          # redraw the Installer and disk image art (AppKit only)
scripts/release.sh --skip-notarize              # signed .pkg and .dmg in build/release/VERSION/, nothing sent to Apple
scripts/release.sh                              # the release: also notarizes and staples both
scripts/build-pkg.sh --unsigned APP OUT.pkg     # a package from any built app with the helper and the CLI inside
```

`scripts/build-pkg.sh` needs a Developer ID Installer certificate for `DEVELOPMENT_TEAM` (or `--unsigned`). It checks
that the app carries the current `latchkey-setup.sh` and the command-line tool, and fills the version and the macOS
gate into the Distribution and its messages from `App/project.yml`.

`scripts/test-installer.sh` checks the package sources exist and parse; the Distribution gates on the deployment
target and asks to quit Latchkey; the App Store build leaves the helper out; `postinstall` stages nothing in a shared
folder and verifies the signature before it runs the helper as the user; the owner and whether the welcome opens for
each kind of install; and the helper's decisions against a fake app, a stub `lsregister` fed a fixture dump, and
stubbed `pluginkit`, `sleep`, `pgrep` and `open`. With a built package (`PKG=…`, or the newest
`build/release/*/Latchkey-*.pkg`) it also checks the payload path, that the package carries the current
`postinstall`, Distribution and helper, and its signature and notarization when present.

## Testing an install

```bash
sudo installer -pkg build/release/VERSION/Latchkey-VERSION.pkg -target /    # command line: no welcome
open build/release/VERSION/Latchkey-VERSION.pkg                              # the full Installer flow
```

Afterwards `~/Library/Logs/Latchkey/setup.log` lists what the helper did, `ls -l ~/.local/bin/latchkey` points into
`/Applications/Latchkey.app`, and `latchkey status` answers. An unsigned or unnotarized package installs only on the
Mac that built it.
