#!/bin/zsh
# Builds a Developer ID release: a notarized, stapled Latchkey.app with the command-line tool inside it, in a
# notarized, stapled disk image.
#
#   scripts/release.sh                  build, sign, notarize, staple → build/release/<version>/Latchkey-<version>.dmg
#   scripts/release.sh --skip-notarize  build and sign only (to check signing without submitting to Apple)
#
# Needs, once per Mac:
#   - A "Developer ID Application" certificate for DEVELOPMENT_TEAM (App/project.yml), in your login keychain.
#     Xcode › Settings › Accounts › your team › Manage Certificates › + › Developer ID Application.
#   - Xcode signed in to that team (exporting creates the Developer ID provisioning profile the keychain
#     entitlement needs).
#   - Notary credentials saved under a keychain profile (default name latchkey-notary; override with
#     LATCHKEY_NOTARY_PROFILE):
#       xcrun notarytool store-credentials latchkey-notary --apple-id YOUR_APPLE_ID --team-id TEAM
#     It asks for an app-specific password (appleid.apple.com › Sign-In and Security › App-Specific Passwords).
set -euo pipefail
cd "${0:A:h}/.."

NOTARIZE=1
[[ "${1:-}" == "--skip-notarize" ]] && NOTARIZE=0
PROFILE="${LATCHKEY_NOTARY_PROFILE:-latchkey-notary}"
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *"\{0,1\}\([A-Z0-9]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)
OUT="build/release/$VERSION"
REG="$HOME/Projects/_worktrees/.register/reg"
build() { if [[ -x "$REG" ]]; then "$REG" build --label latchkey-release -- "$@"; else "$@"; fi }
step() { print -P "%B==> $1%b" }
die() { print -u2 "release: $1"; exit 1 }

# ---------------------------------------------------------------- preflight
[[ -n "$TEAM" ]] || die "set DEVELOPMENT_TEAM in App/project.yml"
[[ -n "$VERSION" ]] || die "set MARKETING_VERSION in App/project.yml"
IDENTITY=$(security find-identity -v -p codesigning | awk -v t="($TEAM)\"" '/"Developer ID Application:/ && index($0, t) {print $2; exit}')
[[ -n "$IDENTITY" ]] || die "no Developer ID Application certificate for team $TEAM in your keychain (see the top of this script)"
if (( NOTARIZE )); then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "no notary credentials under keychain profile '$PROFILE' (see the top of this script)"
fi
command -v xcodegen >/dev/null || die "xcodegen is required: brew install xcodegen"
[[ -e "$OUT" ]] && rm -rf "$OUT"
mkdir -p "$OUT"
step "Latchkey $VERSION, team $TEAM$( (( NOTARIZE )) || print ', not notarizing')"

# ---------------------------------------------------------------- build
step "Building the command-line tool (Apple silicon and Intel)"
build swift build -c release --arch arm64 --arch x86_64 --product latchkey
CLI="$(build swift build -c release --arch arm64 --arch x86_64 --show-bin-path | tail -1)/latchkey"
[[ -x "$CLI" ]] || die "the universal build didn't produce $CLI"

step "Archiving the app"
(cd App && xcodegen -q)
build xcodebuild -quiet -project App/Latchkey.xcodeproj -scheme Latchkey -configuration Release \
  -archivePath "$OUT/Latchkey.xcarchive" -destination 'generic/platform=macOS' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" archive

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
build xcodebuild -quiet -exportArchive -archivePath "$OUT/Latchkey.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates
APP="$OUT/export/Latchkey.app"
[[ -d "$APP" ]] || die "export didn't produce $APP"

# ---------------------------------------------------------------- the CLI inside the app
# Settings › Install Command Line Tool links ~/.local/bin/latchkey to it. Adding a file changes the bundle, so the
# app is signed again afterwards with the entitlements and provisioning profile the export gave it.
step "Embedding and signing the command-line tool"
mkdir -p "$APP/Contents/Helpers"
cp "$CLI" "$APP/Contents/Helpers/latchkey"
codesign --force --options runtime --timestamp --identifier io.snackstud.latchkey.cli --sign "$IDENTITY" "$APP/Contents/Helpers/latchkey"
codesign -d --entitlements - --xml "$APP" > "$OUT/entitlements.plist" 2>/dev/null
codesign --force --options runtime --timestamp --entitlements "$OUT/entitlements.plist" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -1
grep -q "keychain-access-groups" "$OUT/entitlements.plist" || die "the signed app lost its keychain entitlement"

# ---------------------------------------------------------------- notarize
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/notary-$(basename "$1").json" \
    || die "notarization failed for $1 (details: xcrun notarytool log <id> --keychain-profile $PROFILE)"
  grep -q '"status" *: *"Accepted"' "$OUT/notary-$(basename "$1").json" \
    || die "Apple didn't accept $1: $(cat "$OUT/notary-$(basename "$1").json")"
}
if (( NOTARIZE )); then
  step "Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/Latchkey.zip"
  notarize "$OUT/Latchkey.zip"
  xcrun stapler staple -q "$APP"
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -1
fi

# ---------------------------------------------------------------- disk image
step "Building the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Latchkey.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Latchkey-$VERSION.dmg"
hdiutil create -quiet -volname "Latchkey $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if (( NOTARIZE )); then
  step "Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple -q "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | tail -1
fi
# Named by file alone, so `shasum -c` works next to a downloaded copy.
(cd "${DMG:h}" && shasum -a 256 "${DMG:t}") | tee "$DMG.sha256"

# The update feed Latchkey's updater reads (published with the site). Needs Sparkle's sign_update, from the resolved
# package or SPARKLE_BIN, and the EdDSA key made by generate_keys in your login keychain; without them it's skipped.
step "Signing the update for the appcast"
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)
MIN_OS=$(sed -n 's/^ *macOS: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)
SIGN_UPDATE=""
for candidate in "${SPARKLE_BIN:+$SPARKLE_BIN/sign_update}" \
    ~/Library/Developer/Xcode/DerivedData/Latchkey-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update(N); do
  [[ -n "$candidate" && -x "$candidate" ]] && { SIGN_UPDATE="$candidate"; break; }
done
if [[ -z "$SIGN_UPDATE" ]]; then
  print "    (no appcast: sign_update not found. Set SPARKLE_BIN to Sparkle's bin folder, or build the app once so Xcode resolves the package)"
elif [[ -z "$BUILD" || -z "$MIN_OS" ]]; then
  print "    (no appcast: couldn't read CURRENT_PROJECT_VERSION and the deployment target from App/project.yml)"
elif SIGNATURE=$("$SIGN_UPDATE" "$DMG" 2>"$OUT/sign_update.log") && [[ "$SIGNATURE" == *edSignature=* ]]; then
  python3 scripts/update-appcast.py --appcast site/appcast.xml --version "$VERSION" --build "$BUILD" \
    --min-os "$MIN_OS" --signature "$SIGNATURE" && print "    site/appcast.xml now lists $VERSION: publish it with the site"
else
  print "    (no appcast: sign_update failed, usually because there's no Sparkle key in your keychain; run generate_keys once. See $OUT/sign_update.log)"
fi

# The Homebrew cask, once there's a public place to download from (LATCHKEY_RELEASES_REPO, as owner/name) and a
# homepage (LATCHKEY_HOMEPAGE).
if [[ -n "${LATCHKEY_RELEASES_REPO:-}" && -n "${LATCHKEY_HOMEPAGE:-}" ]]; then
  step "Writing the Homebrew cask"
  sed -e "s|@VERSION@|$VERSION|" -e "s|@SHA256@|$(cut -d' ' -f1 "$DMG.sha256")|" \
      -e "s|@RELEASES_REPO@|$LATCHKEY_RELEASES_REPO|" -e "s|@HOMEPAGE@|$LATCHKEY_HOMEPAGE|" \
      packaging/homebrew/latchkey.rb.template | grep -v '^#' > "$OUT/latchkey.rb"
  print "    $OUT/latchkey.rb"
else
  print "    (no Homebrew cask: set LATCHKEY_RELEASES_REPO and LATCHKEY_HOMEPAGE to write one)"
fi
step "Done: $DMG"
