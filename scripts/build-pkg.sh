#!/bin/zsh
# Builds Latchkey's installer package from a Developer ID-signed Latchkey.app (docs/installer.md).
#
#   scripts/build-pkg.sh <Latchkey.app> <out.pkg>              signed with Developer ID Installer for DEVELOPMENT_TEAM
#   scripts/build-pkg.sh --unsigned <Latchkey.app> <out.pkg>   unsigned, to try the Installer flow on this Mac
#
# scripts/release.sh runs it, then notarizes and staples the result. The package installs Latchkey.app into
# /Applications (not relocatable), asks to quit a running Latchkey, refuses a macOS older than the deployment target
# in App/project.yml, and runs packaging/pkg/scripts/postinstall, which starts the app's own setup helper.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

SIGN=1
[[ "${1:-}" == "--unsigned" ]] && { SIGN=0; shift; }
APP="${1:?usage: build-pkg.sh [--unsigned] <Latchkey.app> <out.pkg>}"
OUT="${2:?usage: build-pkg.sh [--unsigned] <Latchkey.app> <out.pkg>}"
APP="${APP:A}" OUT="${OUT:A}"
die() { print -u2 "build-pkg: $1"; exit 1 }

TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *"\{0,1\}\([A-Z0-9]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)
MIN_OS=$(sed -n 's/^ *macOS: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)
[[ -n "$VERSION" && -n "$MIN_OS" ]] || die "couldn't read MARKETING_VERSION and the deployment target from App/project.yml"
PKG="$ROOT/packaging/pkg"

[[ -d "$APP" ]] || die "no app at $APP"
[[ -f "$APP/Contents/Resources/latchkey-setup.sh" ]] || die "$APP has no Contents/Resources/latchkey-setup.sh"
cmp -s "$APP/Contents/Resources/latchkey-setup.sh" "$PKG/latchkey-setup.sh" \
  || die "$APP carries an older latchkey-setup.sh than packaging/pkg/; rebuild the app"
[[ -x "$APP/Contents/Helpers/latchkey" ]] || die "$APP has no command-line tool in Contents/Helpers"
codesign --verify --deep --strict "$APP" || die "$APP's signature doesn't verify"
if (( SIGN )); then
  [[ -n "$TEAM" ]] || die "set DEVELOPMENT_TEAM in App/project.yml"
  IDENTITY=$(security find-identity -v | awk -v t="($TEAM)\"" '/"Developer ID Installer:/ && index($0, t) {print $2; exit}')
  [[ -n "$IDENTITY" ]] || die "no Developer ID Installer certificate for team $TEAM in your keychain (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Installer), or pass --unsigned"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/latchkey-pkg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/scripts" "$WORK/resources" "${OUT:h}"
ditto "$APP" "$WORK/root/Applications/Latchkey.app"
install -m 0755 "$PKG/scripts/postinstall" "$WORK/scripts/postinstall"

# Component: Latchkey.app at /Applications, never relocated to another copy the user has.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$WORK/component.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/component.plist"
/usr/libexec/PlistBuddy -c "Delete :0:BundleOverwriteAction" "$WORK/component.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleOverwriteAction string upgrade" "$WORK/component.plist"
pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts "$WORK/scripts" \
  --identifier io.snackstud.latchkey.pkg --version "$VERSION" --install-location / "$WORK/Latchkey-component.pkg"

# The version and the macOS gate come from App/project.yml.
fill() { sed -e "s/@VERSION@/$VERSION/g" -e "s/@MIN_OS@/$MIN_OS/g" "$1" > "$2" }
fill "$PKG/Distribution.xml" "$WORK/Distribution.xml"
cp "$PKG"/resources/background*.png "$WORK/resources/"
mkdir -p "$WORK/resources/en.lproj"
for f in "$PKG"/resources/en.lproj/*; do fill "$f" "$WORK/resources/en.lproj/${f:t}"; done

[[ -e "$OUT" ]] && rm -f "$OUT"
if (( SIGN )); then
  productbuild --quiet --distribution "$WORK/Distribution.xml" --resources "$WORK/resources" --package-path "$WORK" \
    --sign "$IDENTITY" --timestamp "$OUT"
  pkgutil --check-signature "$OUT" | sed -n '1,3p'
else
  productbuild --quiet --distribution "$WORK/Distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$OUT"
  print "    unsigned: Gatekeeper will refuse it on another Mac"
fi
print "    $OUT"
