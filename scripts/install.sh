#!/bin/zsh
# Builds Latchkey and installs it:
#   app → /Applications/Latchkey.app      CLI → ~/.local/bin/latchkey  (override with LATCHKEY_BIN_DIR)
#
# With DEVELOPMENT_TEAM set in App/project.yml the app is signed with your team and keeps values in
# iCloud Keychain. Without it, the app is signed ad hoc and keeps values in this Mac's login keychain.
set -euo pipefail
cd "${0:A:h}/.."

BIN_DIR="${LATCHKEY_BIN_DIR:-$HOME/.local/bin}"
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
# The app tells its own tool from any other program on its socket by this signature, and the tool checks the app's.
if [[ -n "$TEAM" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -v t="($TEAM)\"" '/"(Apple Development|Developer ID Application):/ && index($0, t) {print $2; exit}')
  if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp=none --identifier io.snackstud.latchkey.cli --sign "$IDENTITY" "$BIN_DIR/latchkey"
  else
    echo "    no signing certificate for team $TEAM: the command-line tool stays unsigned, and approvals will say so" >&2
  fi
fi

open /Applications/Latchkey.app
for _ in {1..20}; do
  "$BIN_DIR/latchkey" status >/dev/null 2>&1 && break
  sleep 0.5
done

echo
echo "Installed /Applications/Latchkey.app and $BIN_DIR/latchkey"
"$BIN_DIR/latchkey" status
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on your PATH" ;; esac
