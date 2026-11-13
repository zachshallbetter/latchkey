#!/bin/zsh
# Builds Latchkey's disk image with its window laid out (packaging/dmg/settings.py): the background, Latchkey and an
# Applications link either side of an arrow, at 128-point icons.
#
#   scripts/make-dmg.sh <Latchkey.app> <out.dmg> [volume name]
#
# dmgbuild runs from a private virtual environment under build/, pinned to one version, so building the image never
# opens Finder or needs anything installed system-wide.
set -euo pipefail
ROOT="${0:A:h:h}"
APP="${1:?usage: make-dmg.sh <Latchkey.app> <out.dmg> [volume name]}"
OUT="${2:?usage: make-dmg.sh <Latchkey.app> <out.dmg> [volume name]}"
NAME="${3:-Latchkey}"
DMGBUILD_VERSION="1.6.5"  # newest that runs on macOS's own python3
VENV="${DMG_VENV:-$ROOT/build/dmgbuild-venv}"
if [[ ! -x "$VENV/bin/dmgbuild" ]] || ! "$VENV/bin/python" -m pip show dmgbuild 2>/dev/null | grep -q "^Version: $DMGBUILD_VERSION$"; then
  /usr/bin/python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
fi
[[ -e "$OUT" ]] && rm -f "$OUT"
"$VENV/bin/dmgbuild" -s "$ROOT/packaging/dmg/settings.py" -D app="$APP" -D here="$ROOT/packaging/dmg" "$NAME" "$OUT"
