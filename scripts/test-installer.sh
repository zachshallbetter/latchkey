#!/usr/bin/env bash
# Tests the installer package's sources and decisions without installing, registering or linking anything for real
# (docs/installer.md):
#
# - The package sources exist and parse; the Distribution gates on App/project.yml's deployment target and asks to
#   quit Latchkey; the app carries the setup helper and the App Store build doesn't.
# - packaging/pkg/scripts/postinstall stages nothing in a shared folder, verifies the app's signature before it runs
#   the helper from inside the app, gives a shared app to root:admin on command-line and MDM installs and to the
#   user at the screen otherwise, and opens the welcome only for an Installer-app install.
# - packaging/pkg/latchkey-setup.sh links the command-line tool through the app (a stub that records its
#   arguments), unregisters only other copies with `lsregister -u` (a stub fed a fixture dump), only reads the Safari
#   extension's state, and opens Latchkey only with --open.
# - With a built package (PKG=…, or the newest build/release/*/Latchkey-*.pkg), its payload path, scripts,
#   Distribution and signature.
#
#   scripts/test-installer.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/packaging/pkg"
SETUP="$PKG_DIR/latchkey-setup.sh"
POSTINSTALL="$PKG_DIR/scripts/postinstall"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/latchkey-installer-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
expect() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check() { # name command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
# Script lines that aren't comments.
code() { grep -vE '^[[:space:]]*#' "$1"; }

MIN_OS="$(sed -n 's/^ *macOS: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\} *$/\1/p' "$ROOT/App/project.yml" | head -1)"

echo "== package sources"

for f in Distribution.xml latchkey-setup.sh scripts/postinstall resources/background.png resources/background-dark.png \
         resources/en.lproj/welcome.html resources/en.lproj/conclusion.html resources/en.lproj/Localizable.strings; do
  check "exists: packaging/pkg/$f" test -s "$PKG_DIR/$f"
done
check "exists: packaging/dmg/background.tiff" test -s "$ROOT/packaging/dmg/background.tiff"
check "exists: packaging/dmg/settings.py" test -s "$ROOT/packaging/dmg/settings.py"
sed -e "s/@VERSION@/0.0.0/g" -e "s/@MIN_OS@/$MIN_OS/g" "$PKG_DIR/Distribution.xml" > "$WORK/Distribution.xml"
check "Distribution parses as XML once filled in" xmllint --noout "$WORK/Distribution.xml"
check "Localizable.strings parses" plutil -lint "$PKG_DIR/resources/en.lproj/Localizable.strings"
check "postinstall parses" bash -n "$POSTINSTALL"
check "setup helper parses" bash -n "$SETUP"
check "postinstall is executable" test -x "$POSTINSTALL"
expect "deployment target read from App/project.yml" 1 "$([[ "$MIN_OS" =~ ^[0-9]+(\.[0-9]+)*$ ]] && echo 1 || echo 0)"
expect "installation check compares with the deployment target" 1 \
  "$(grep -c "compareVersions(system.version.ProductVersion, '$MIN_OS')" "$WORK/Distribution.xml")"
expect "volume check has the deployment target" 1 "$(grep -c "<os-version min=\"$MIN_OS\"/>" "$WORK/Distribution.xml")"
expect "nothing left to fill in" 0 "$(grep -c '@[A-Z_]*@' "$WORK/Distribution.xml" || true)"
expect "Distribution asks to quit Latchkey" 1 "$(grep -c '<app id="io.snackstud.latchkey"/>' "$WORK/Distribution.xml")"
expect "Distribution installs on the system volume only" 1 "$(grep -c 'enable_localSystem="true"' "$WORK/Distribution.xml")"
expect "Distribution has light and dark art" 2 "$(grep -cE '<background(-darkAqua)? file="background(-dark)?.png"' "$WORK/Distribution.xml")"
for page in welcome conclusion; do
  expect "$page.html has no grid, flex or block backgrounds (Installer's renderer)" 0 \
    "$(grep -cE 'display: *(grid|flex)|background(-color)? *:' "$PKG_DIR/resources/en.lproj/$page.html" || true)"
done
expect "the app carries the setup helper" 1 "$(grep -c 'path: ../packaging/pkg/latchkey-setup.sh' "$ROOT/App/project.yml")"
expect "the App Store build replaces the app's sources" 1 "$(grep -c 'sources:REPLACE:' "$ROOT/App/project.appstore.yml")"
expect "the App Store build leaves the setup helper out" 0 "$(grep -c 'latchkey-setup' "$ROOT/App/project.appstore.yml" || true)"

echo "== postinstall: what it may do"

expect "postinstall stages nothing in a shared folder" 0 \
  "$(code "$POSTINSTALL" | grep -cE '/tmp|/private/var|/Users/Shared|mktemp' || true)"
expect "postinstall runs the helper from inside the app" 1 \
  "$(code "$POSTINSTALL" | grep -c 'helper="$app/Contents/Resources/latchkey-setup.sh"')"
verify_line="$(code "$POSTINSTALL" | grep -n 'codesign --verify --strict "$app"' | cut -d: -f1 | head -1)"
run_line="$(code "$POSTINSTALL" | grep -n '/bin/bash "$helper"' | cut -d: -f1 | head -1)"
expect "postinstall verifies the signature before it runs the helper" 1 \
  "$([[ -n "$verify_line" && -n "$run_line" && "$verify_line" -lt "$run_line" ]] && echo 1 || echo 0)"
expect "postinstall runs the helper as the user, not root" 1 "$(code "$POSTINSTALL" | grep -c 'launchctl asuser "$user_id" /usr/bin/sudo -H -u "$user"')"
expect "the helper never switches extensions or resets PluginKit" 0 "$(code "$SETUP" | grep -cE 'pluginkit +-(e|r|a)' || true)"
expect "the helper only unregisters and reads with lsregister" 0 \
  "$(code "$SETUP" | grep -E '"\$LSREGISTER"' | grep -vcE '"\$LSREGISTER" -(u|dump)' || true)"
expect "the helper never touches the keychain or System Settings" 0 \
  "$(code "$SETUP" | grep -cE '\bsecurity |defaults write|systemsetup|sudo ' || true)"

# shellcheck source=../packaging/pkg/scripts/postinstall
source "$POSTINSTALL"
set +e
expect "owner: Installer app, user at the screen" "pat:admin" "$(app_owner pat "")"
expect "owner: command-line install, user at the screen" "root:admin" "$(app_owner pat 1)"
expect "owner: command-line install, nobody at the screen" "root:admin" "$(app_owner "" 1)"
expect "owner: nobody at the screen (MDM)" "root:admin" "$(app_owner "" "")"
expect "helper: Installer app opens the welcome" "--app /A.app --open" "$(helper_args /A.app "" | xargs)"
expect "helper: command-line install doesn't" "--app /A.app" "$(helper_args /A.app 1 | xargs)"

echo "== setup helper"

# A fake app whose executable records how it was run, and fake system tools.
APP_FAKE="$WORK/Applications/Latchkey.app"
mkdir -p "$APP_FAKE/Contents/MacOS" "$APP_FAKE/Contents/Helpers" "$WORK/home"
CALLS="$WORK/calls"
cat > "$APP_FAKE/Contents/MacOS/Latchkey" <<EOF
#!/bin/bash
printf 'app %s\n' "\$*" >> "$CALLS"
echo "Installed ~/.local/bin/latchkey and ~/.local/bin/lk. Make sure ~/.local/bin is on your PATH."
EOF
printf '#!/bin/sh\n' > "$APP_FAKE/Contents/Helpers/latchkey"
chmod 755 "$APP_FAKE/Contents/MacOS/Latchkey" "$APP_FAKE/Contents/Helpers/latchkey"

# lsregister -dump in its usual shape: three copies of Latchkey and one other app.
cat > "$WORK/dump.txt" <<EOF
--------------------------------------------------------------------------------
path:                       $APP_FAKE (0x1a2b)
identifier:                 io.snackstud.latchkey
--------------------------------------------------------------------------------
path:                       /Volumes/Latchkey 0.4.0/Latchkey.app (0x1a2c)
identifier:                 io.snackstud.latchkey
--------------------------------------------------------------------------------
path:                       /Users/pat/Downloads/Latchkey.app (0x1a2d)
identifier:                 io.snackstud.latchkey
--------------------------------------------------------------------------------
path:                       /Applications/Peel.app (0x1a2e)
identifier:                 io.snackstud.peel
--------------------------------------------------------------------------------
path:                       /Users/pat/Downloads/Latchkey.app/Contents/PlugIns/LatchkeySafari.appex (0x1a2f)
identifier:                 io.snackstud.latchkey.safari
EOF
cat > "$WORK/lsregister" <<EOF
#!/bin/bash
printf 'lsregister %s\n' "\$*" >> "$CALLS"
[[ "\$1" == -dump ]] && cat "$WORK/dump.txt"
exit 0
EOF
chmod 755 "$WORK/lsregister"

# shellcheck source=../packaging/pkg/latchkey-setup.sh
source "$SETUP"
set +e  # the helper turns errexit on; the checks below handle failures themselves
APP="$APP_FAKE"
LSREGISTER="$WORK/lsregister"
USER_HOME="$WORK/home"
LOG="$WORK/setup.log"

expect "copies found in the dump" \
  "$(printf '%s\n' "$APP_FAKE" "/Users/pat/Downloads/Latchkey.app" "/Volumes/Latchkey 0.4.0/Latchkey.app" | sort)" \
  "$(registered_copies)"

: > "$CALLS"
unregister_other_copies
expect "other copies unregistered with -u, this one kept" \
  "$(printf '%s\n' "lsregister -dump" "lsregister -u /Users/pat/Downloads/Latchkey.app" "lsregister -u /Volumes/Latchkey 0.4.0/Latchkey.app")" \
  "$(sort "$CALLS")"
expect "unregistering is logged" 2 "$(grep -c 'unregistered other copy' "$LOG")"

: > "$CALLS"
install_links
expect "links installed through the app" "app --install-command-line-tool" "$(cat "$CALLS")"
expect "the app's answer is logged" 1 "$(grep -c 'command-line tool: Installed ~/.local/bin/latchkey' "$LOG")"

mv "$APP_FAKE/Contents/Helpers/latchkey" "$WORK/latchkey.away"
: > "$CALLS"
install_links
expect "no bundled tool: the app isn't run" "" "$(cat "$CALLS")"
mv "$WORK/latchkey.away" "$APP_FAKE/Contents/Helpers/latchkey"

pluginkit() { printf '+    io.snackstud.latchkey.safari(0.4.0)\n'; }
expect "Safari extension on" "+" "$(safari_extension_state)"
pluginkit() { printf -- '-    io.snackstud.latchkey.safari(0.4.0)\n'; }
expect "Safari extension off" "-" "$(safari_extension_state)"
pluginkit() { :; }
expect "Safari extension not known yet" "" "$(safari_extension_state)"
unset -f pluginkit

# The whole run with every side effect stubbed; sleep is instant and Installer has closed.
run_main() {
  : > "$CALLS"
  (
    pluginkit() { :; }
    sleep() { :; }
    pgrep() { return 1; }
    open() { echo "open $*" >> "$CALLS"; }
    main --app "$APP_FAKE" "$@"
  ) >/dev/null 2>&1
  echo "exit=$?"
}
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip  full runs: the helper refuses to run as root"
else
  expect "full run: exits cleanly" "exit=0" "$(run_main)"
  expect "full run: links, looks up copies, unregisters two" "1/1/2" \
    "$(grep -c '^app --install-command-line-tool' "$CALLS")/$(grep -c '^lsregister -dump' "$CALLS")/$(grep -c '^lsregister -u' "$CALLS")"
  expect "full run: Latchkey not opened without --open" 0 "$(grep -c '^open ' "$CALLS" || true)"
  run_main --open >/dev/null
  expect "full run with --open: opens the welcome once" "open $APP_FAKE --args -LatchkeyWelcome YES" "$(grep '^open ' "$CALLS")"
  : > "$CALLS"
  (main --app "$WORK/none.app") >/dev/null 2>&1
  expect "full run: no app, nothing run" "exit=$?/0" "exit=0/$(wc -l < "$CALLS" | tr -d ' ')"
fi

echo "== disk image"

expect "disk image icons sit either side of the arrow" 2 \
  "$(grep -cE '"(Latchkey.app|Applications)": \((170|470), 210\)' "$ROOT/packaging/dmg/settings.py")"
expect "Sparkle signs the disk image, not the package" 1 "$(grep -c 'SIGN_UPDATE" --account latchkey "$DMG"' "$ROOT/scripts/release.sh")"
expect "the disk image is laid out by make-dmg.sh" 1 "$(grep -c 'scripts/make-dmg.sh "$APP" "$DMG"' "$ROOT/scripts/release.sh")"
expect "test builds never write the appcast" 1 "$(grep -c 'no appcast: --skip-notarize' "$ROOT/scripts/release.sh")"

echo "== built package"

PKG="${PKG:-$(ls -t "$ROOT"/build/release/*/Latchkey-*.pkg "$ROOT"/build/pkg/Latchkey-*.pkg 2>/dev/null | head -1 || true)}"
if [[ -z "$PKG" || ! -f "$PKG" ]]; then
  echo "skip  no built package (scripts/build-pkg.sh, or set PKG=)"
else
  echo "      $PKG"
  pkgutil --expand-full "$PKG" "$WORK/expanded" >/dev/null
  component="$(ls -d "$WORK"/expanded/*.pkg | head -1)"
  packaged="$WORK/expanded/Distribution"
  check "postinstall in the package is the current one" cmp -s "$POSTINSTALL" "$component/Scripts/postinstall"
  check "payload is Latchkey.app in /Applications" test -d "$component/Payload/Applications/Latchkey.app"
  check "the packaged app carries the current helper" \
    cmp -s "$SETUP" "$component/Payload/Applications/Latchkey.app/Contents/Resources/latchkey-setup.sh"
  check "the packaged app carries the command-line tool" test -x "$component/Payload/Applications/Latchkey.app/Contents/Helpers/latchkey"
  # productbuild rewrites the Distribution, so check what it must still say.
  expect "packaged Distribution: macOS gate" 2 \
    "$(grep -cE "compareVersions\(system.version.ProductVersion, '$MIN_OS'\)|<os-version min=\"$MIN_OS\"/>" "$packaged")"
  expect "packaged Distribution: asks to quit Latchkey" 1 "$(grep -c '<app id="io.snackstud.latchkey"/>' "$packaged")"
  expect "packaged Distribution: welcome, summary and art" 4 \
    "$(grep -cE '<(welcome|conclusion|background|background-darkAqua) file=' "$packaged")"
  expect "packaged Distribution: nothing left to fill in" 0 "$(grep -c '@[A-Z_]*@' "$packaged" || true)"
  expect "packaged messages: nothing left to fill in" 0 \
    "$(grep -c '@[A-Z_]*@' "$WORK/expanded/Resources/en.lproj/"* | awk -F: '{s+=$2} END {print s+0}')"
  if pkgutil --check-signature "$PKG" 2>/dev/null | grep -q 'Developer ID Installer'; then
    pass "signed with Developer ID Installer"
    if spctl --assess --type install "$PKG" 2>/dev/null; then pass "notarized (Gatekeeper accepts it)"
    else echo "skip  not notarized (scripts/release.sh without --skip-notarize)"; fi
  else
    echo "skip  unsigned package (scripts/build-pkg.sh --unsigned)"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
