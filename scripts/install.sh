#!/bin/zsh
# Builds Latchkey and installs it:
#   app → /Applications/Latchkey.app      CLI → ~/.local/bin/latchkey  (override with LATCHKEY_BIN_DIR)
#
# With DEVELOPMENT_TEAM set in App/project.yml the app is signed with your team and keeps values in
# iCloud Keychain. Without it, the app is signed ad hoc and keeps values in this Mac's login keychain.
set -euo pipefail
cd "${0:A:h}/.."

BIN_DIR="${LATCHKEY_BIN_DIR:-$HOME/.local/bin}"
DERIVED=build/DerivedData
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *"\{0,1\}\([A-Z0-9]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)

echo "==> Building the command-line tool"
swift build -c release --product latchkey

echo "==> Building the app"
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
(cd App && xcodegen -q)
if [[ -n "$TEAM" ]]; then
  echo "    signing with team $TEAM (iCloud Keychain)"
  SIGN=(-allowProvisioningUpdates)
else
  echo "    no DEVELOPMENT_TEAM in App/project.yml: signing ad hoc (login keychain, this Mac only)"
  # The keychain-access-groups entitlement needs a real team; an ad hoc app that claims it will not launch.
  SIGN=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM=)
fi
xcodebuild -quiet -project App/Latchkey.xcodeproj -scheme Latchkey -configuration Release \
  -derivedDataPath "$DERIVED" "${SIGN[@]}" build

echo "==> Installing"
osascript -e 'tell application id "io.latchkey.Latchkey" to quit' >/dev/null 2>&1 || true
pkill -x Latchkey 2>/dev/null || true
pkill -f '/latchkey-broker$' 2>/dev/null || true
sleep 1
rm -rf /Applications/Latchkey.app
ditto "$DERIVED/Build/Products/Release/Latchkey.app" /Applications/Latchkey.app
mkdir -p "$BIN_DIR"
install -m 0755 .build/release/latchkey "$BIN_DIR/latchkey"

open /Applications/Latchkey.app
for _ in {1..20}; do
  "$BIN_DIR/latchkey" status >/dev/null 2>&1 && break
  sleep 0.5
done

echo
echo "Installed /Applications/Latchkey.app and $BIN_DIR/latchkey"
"$BIN_DIR/latchkey" status
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on your PATH" ;; esac
