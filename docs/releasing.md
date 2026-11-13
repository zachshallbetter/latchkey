# Releasing

This page describes direct Developer ID distribution. Mac App Store preparation, the sandbox experiment and
full-functionality submission gates are in [App Store preparation](app-store.md). Notarization is not an
App Store upload, and the direct release script must not be used to manufacture a store package.

A release is a Developer ID-signed, notarized and stapled `Latchkey.app`, with the command-line tool inside it, in a
signed, notarized and stapled installer package (the recommended download; see [Installer](installer.md)) and a
signed, notarized and stapled disk image (drag installs, Sparkle updates and the Homebrew cask).

## Once per Mac

1. **Developer ID certificates.** Xcode › Settings › Accounts › your team › **Manage Certificates** › **+** ›
   **Developer ID Application**, then **+** › **Developer ID Installer** for the package. Only the account holder or
   an admin of a paid Apple Developer Program team can make them. `security find-identity -v` should list
   `Developer ID Application: … (TEAM)` and `Developer ID Installer: … (TEAM)`.
2. **Notary credentials.** Make an app-specific password at appleid.apple.com › Sign-In and Security ›
   App-Specific Passwords, then save it in your keychain:

   ```bash
   xcrun notarytool store-credentials latchkey-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

   The script uses the profile `latchkey-notary`; set `LATCHKEY_NOTARY_PROFILE` to use another.
3. **Xcode signed in to the team.** Exporting creates the Developer ID provisioning profile that the keychain
   entitlement needs.
4. **Update signing key** (once, ever). The direct download updates itself with Sparkle, which checks each update
   against an EdDSA key. Resolve the package once (build the app in Xcode, or `cd App && xcodegen && xcodebuild
   -resolvePackageDependencies -project Latchkey.xcodeproj -scheme Latchkey`), then run Sparkle's tool:

   ```bash
   ~/Library/Developer/Xcode/DerivedData/Latchkey-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account latchkey
   ```

   It stores the private key in your login keychain under the `latchkey` account, which `release.sh` signs with
   (back it up: `generate_keys --account latchkey -x file`; a lost key means users
   can't update without reinstalling) and prints the public key. Put that in `SPARKLE_PUBLIC_KEY` in
   `App/project.yml`. While it is empty the updater doesn't start and builds still work. Never commit the private key.
   The key was made on 2026-11-13; `generate_keys --account latchkey -p` prints its public half.

## Making a release

1. Set `MARKETING_VERSION` (and raise `CURRENT_PROJECT_VERSION`) in `App/project.yml`, and move the
   `CHANGELOG.md` entry from "unreleased" to the date.
2. Check: `swift test`, and the app built and tried with `scripts/install.sh`.
3. Build:

   ```bash
   scripts/release.sh
   ```

   It builds a universal (Apple silicon and Intel) command-line tool, archives the app (which carries the package's
   setup helper in `Contents/Resources/latchkey-setup.sh`), exports it with Developer ID, puts the tool in
   `Latchkey.app/Contents/Helpers/latchkey` and signs both, and notarizes and staples the app. Then it builds
   `build/release/VERSION/Latchkey-VERSION.pkg` with `scripts/build-pkg.sh` (signed with Developer ID Installer) and
   `Latchkey-VERSION.dmg` with `scripts/make-dmg.sh` (the laid-out window), notarizes and staples both, and writes
   each one's SHA-256 next to it. `scripts/release.sh --skip-notarize` stops before submitting anything to Apple, to
   check signing, and writes no appcast entry.

   If Sparkle's `sign_update` is found (`SPARKLE_BIN`, the folder holding it, or the package Xcode resolved) and your
   keychain has the key, it then signs the disk image and adds this version to `site/appcast.xml` through
   `scripts/update-appcast.py`: the build and version from `App/project.yml`, the GitHub release URL
   (`https://github.com/zachshallbetter/latchkey/releases/download/vVERSION/Latchkey-VERSION.dmg`), length, signature,
   `minimumSystemVersion` from the deployment target, and a link to the changelog. Otherwise it prints why it skipped
   that step; the release itself never fails for it.

4. Upload the package and the disk image (and their `.sha256` files) to the GitHub release `vVERSION`, then publish `site/appcast.xml` with the site
   (`https://latchkey.snackstud.io/appcast.xml`). Publish it last: running copies see the new version as soon as the
   file is live. Check that the enclosure URL downloads.
5. Check both on a Mac that has never had Latchkey; Gatekeeper should open each without warnings:
   - Open the package: Installer shows the welcome page, asks for a password, and when it closes Latchkey opens its
     welcome with every check green except the optional steps. Run `latchkey status` in a new Terminal window, and
     read `~/Library/Logs/Latchkey/setup.log`.
   - Open the disk image: the window shows the background with Latchkey and Applications either side of the arrow.
     Drag Latchkey to Applications and open it: the welcome opens and offers **Install Command Line Tool**.
   `scripts/test-installer.sh` checks the built package's contents and signature.

## Homebrew

The cask installs from the disk image, not the package: its `app` stanza copies Latchkey to Applications and its
`binary` stanzas link `latchkey` and `lk` into Homebrew's own `bin`, so the package's root `postinstall` and setup
helper would add nothing for brew users. The welcome opens on Latchkey's first launch either way.

The script writes `build/release/VERSION/latchkey.rb` from `packaging/homebrew/latchkey.rb.template`: the app,
`latchkey` and `lk` on the PATH, and a `zap` that removes Latchkey's folder and settings (not keychain items). The
download repository and homepage default to `zachshallbetter/latchkey` and https://latchkey.snackstud.io/
(override with `LATCHKEY_RELEASES_REPO` and `LATCHKEY_HOMEPAGE`).

After the GitHub release is published, copy it to the tap,
[zachshallbetter/homebrew-latchkey](https://github.com/zachshallbetter/homebrew-latchkey), as `Casks/latchkey.rb`,
commit and push. People install with `brew tap zachshallbetter/latchkey`, `brew trust zachshallbetter/latchkey` and
`brew install --cask latchkey`.

## What the script checks

- Developer ID Application and Developer ID Installer certificates for `DEVELOPMENT_TEAM` exist.
- The app carries the current setup helper and the command-line tool (`scripts/build-pkg.sh`).
- The notary profile works (unless `--skip-notarize`).
- The re-signed app still has its `keychain-access-groups` entitlement and passes `codesign --verify --deep
  --strict`.
- Apple accepted all three submissions (app, package, disk image), and `spctl` accepts the app, the package (`--type
  install`) and the disk image.

The Mac App Store build has no updater: it excludes Sparkle (`App/project.appstore.yml`, checked by
`scripts/appstore-preflight.py`) and updates through the App Store.

If notarization fails, the JSON for each submission is in `build/release/VERSION/`, and `xcrun notarytool log
SUBMISSION_ID --keychain-profile latchkey-notary` shows Apple's reasons.

## Identity that must not change

The bundle ID (`PRODUCT_BUNDLE_IDENTIFIER`) and the keychain access group (`keychain-access-groups` and
`LatchkeyAccessGroup` in `App/project.yml`), together with the team ID, decide which app can read people's stored
items. Changing any of them after a release leaves existing items unreadable by the new build unless the release
also ships a migration that reads the old group.

They are `io.snackstud.latchkey` and `<TEAM>.io.snackstud.latchkey`. Development builds before 0.1.0 used
`io.latchkey.Latchkey` and `<TEAM>.io.latchkey.shared`; the app keeps the old group in its entitlements
(`LatchkeyPreviousAccessGroup`) and moves anything still there into the new one when it starts
(`StoreMigration.adopt`).
