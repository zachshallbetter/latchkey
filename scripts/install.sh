#!/bin/zsh
# Builds Latchkey and installs it:
#   app → /Applications/Latchkey.app      CLI → ~/.local/bin/latchkey, with pst, pist, pistachio and lk  (override with PISTACHIO_BIN_DIR or LATCHKEY_BIN_DIR)
#
# With DEVELOPMENT_TEAM set in App/project.yml the app is signed with your team and keeps values in
# iCloud Keychain. Without it, the app is signed ad hoc and keeps values in this Mac's login keychain.
set -euo pipefail
cd "${0:A:h}/.."

BIN_DIR="${PISTACHIO_BIN_DIR:-${LATCHKEY_BIN_DIR:-$HOME/.local/bin}}"
# On machines with a shared build register, builds wait for a slot there. Only the builds: the register
# cleans up what runs under it, which would take the freshly opened app with it.
REG="$HOME/Projects/_worktrees/.register/reg"
build() { if [[ -x "$REG" ]]; then "$REG" build --label latchkey -- "$@"; else "$@"; fi }
DERIVED=build/DerivedData
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *"\{0,1\}\([A-Z0-9]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)

echo "==> Building the command-line tool"
build swift build -c release --product latchkey

echo "==> Building the app"
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
(cd App && xcodegen -q)
if [[ -n "$TEAM" ]]; then
  echo "    signing with team $TEAM (iCloud Keychain)"
  # No get-task-allow: a development build would otherwise let any debugger attach to the app holding the keychain.
  SIGN=(-allowProvisioningUpdates CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
else
  echo "    no DEVELOPMENT_TEAM in App/project.yml: signing ad hoc (login keychain, this Mac only)"
  # The keychain-access-groups entitlement needs a real team; an ad hoc app that claims it will not launch.
  SIGN=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM=)
fi
build xcodebuild -quiet -project App/Latchkey.xcodeproj -scheme Latchkey -configuration Release \
  -derivedDataPath "$DERIVED" "${SIGN[@]}" build

echo "==> Installing"
if pgrep -f '/latchkey-broker$' >/dev/null; then
  echo "latchkey-broker is running and answers on the same socket; stop it, then run this again." >&2
  exit 1
fi
osascript -e 'tell application id "io.snackstud.latchkey" to quit' >/dev/null 2>&1 || true
# Wait for the old copy to be gone, or `open` below just wakes the one that is quitting.
for _ in {1..20}; do pgrep -x Latchkey >/dev/null || break; sleep 0.5; done
if pgrep -x Latchkey >/dev/null; then
  echo "Latchkey didn't quit (an approval may be waiting); quit it, then run this again." >&2
  exit 1
fi
rm -rf /Applications/Latchkey.app
ditto "$DERIVED/Build/Products/Release/Latchkey.app" /Applications/Latchkey.app
mkdir -p "$BIN_DIR"
install -m 0755 .build/release/latchkey "$BIN_DIR/latchkey"
# `pst` for short and `pistachio` in full; keep `lk` for existing scripts. Leave existing files alone.
for name in pst pist pistachio lk; do
  if [[ -L "$BIN_DIR/$name" || ! -e "$BIN_DIR/$name" ]]; then ln -sf "$BIN_DIR/latchkey" "$BIN_DIR/$name"; fi
done
# The app tells its own tool from any other program on its socket by this signature, and the tool checks the app's.
if [[ -n "$TEAM" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -v t="($TEAM)\"" '/"(Apple Development|Developer ID Application):/ && index($0, t) {print $2; exit}')
  if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp=none --identifier io.snackstud.latchkey.cli --sign "$IDENTITY" "$BIN_DIR/latchkey"
  else
    echo "    no signing certificate for team $TEAM: the command-line tool stays unsigned, and approvals will say so" >&2
  fi
fi

# Only the installed copy should offer Latchkey's Safari extension. macOS registers every copy it sees (this build
# folder, other worktrees' builds, Xcode archives), and with several registered Safari may resolve the extension to
# one of them, so the app's "Turn On in Safari…" fails with SFErrorDomain error 1. Forget every other copy; the
# files stay where they are.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
{ "$LSREGISTER" -dump 2>/dev/null || true; } | sed -nE 's/^path: +(.*\/Latchkey\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u |
  while IFS= read -r built; do
    [[ "$built" == /Applications/Latchkey.app ]] && continue
    if [[ -d "$built" ]]; then
      id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$built/Contents/Info.plist" 2>/dev/null || true)
      [[ "$id" == io.snackstud.latchkey ]] || continue
      pluginkit -r "$built/Contents/PlugIns/LatchkeySafari.appex" 2>/dev/null || true
    fi
    "$LSREGISTER" -u "$built" 2>/dev/null || true
  done
"$LSREGISTER" -f /Applications/Latchkey.app

open /Applications/Latchkey.app
for _ in {1..20}; do
  "$BIN_DIR/latchkey" status >/dev/null 2>&1 && break
  sleep 0.5
done

echo
echo "Installed /Applications/Latchkey.app and $BIN_DIR/latchkey"
"$BIN_DIR/latchkey" status
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on your PATH" ;; esac
