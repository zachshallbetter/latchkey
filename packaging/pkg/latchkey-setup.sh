#!/bin/bash
# Latchkey's post-install setup, run as the logged-in user (never as root).
#
# Ships inside Latchkey.app (Contents/Resources/latchkey-setup.sh), so it is
# sealed by the app's code signature and nothing is staged in /tmp. The
# installer's postinstall starts it in the background once the app is in
# /Applications (docs/installer.md).
#
#   latchkey-setup.sh [--open] [--app /Applications/Latchkey.app]
#
# 1. Links `latchkey` and `lk` in ~/.local/bin to the tool inside the app, by
#    running the app with --install-command-line-tool: the same code as
#    Latchkey › Install Command Line Tool…, which replaces only links and
#    leaves a file of either name alone.
# 2. Unregisters other copies of io.snackstud.latchkey from Launch Services (a
#    disk image, Downloads, an old install, build folders), so Safari and
#    `open` use the one in /Applications. Their files are never touched, and
#    nothing is removed from PluginKit: that could reset the user's own on/off
#    choice for the Safari extension, which shares Latchkey's identifiers.
# 3. Logs the Safari extension's PluginKit state; it never turns it on or off.
# 4. With --open, opens Latchkey once Installer has closed (Installer keeps
#    focus while it is open, so Latchkey would start behind it), with
#    -LatchkeyWelcome YES, which shows the welcome for that launch only.
#
# It logs to ~/Library/Logs/Latchkey/setup.log. It never changes System
# Settings, Safari's settings or any extension switch, and never touches the
# keychain.
#
# Sourcing it (as scripts/test-installer.sh does) defines the functions and
# runs nothing.
set -euo pipefail

APP="/Applications/Latchkey.app"
OPEN=0

BUNDLE_ID="io.snackstud.latchkey"
SAFARI_ID="io.snackstud.latchkey.safari"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The user's own home, from the directory, not $HOME: a helper started through
# sudo can inherit root's.
USER_HOME="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null \
  | /usr/bin/sed -n 's/^NFSHomeDirectory: //p' || true)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || USER_HOME="$HOME"
LOG="$USER_HOME/Library/Logs/Latchkey/setup.log"

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" || true; }

# Links the command-line tool through the app's own code, in the home folder of
# the account it runs as (the app reads it from the user database, not $HOME).
install_links() {
  local exe="$APP/Contents/MacOS/Latchkey" out
  if [[ ! -x "$APP/Contents/Helpers/latchkey" ]]; then
    log "no command-line tool in $APP; links not installed"
    return 0
  fi
  if out="$("$exe" --install-command-line-tool 2>&1)"; then
    log "command-line tool: $out"
  else
    log "installing the command-line tool failed: $out"
  fi
}

# Bundles Launch Services knows with Latchkey's identifier, one path per line.
registered_copies() {
  { "$LSREGISTER" -dump 2>/dev/null || true; } | awk -v id="$BUNDLE_ID" '
    /^-+$/ { if (path != "" && ident == id) print path; path = ""; ident = ""; next }
    /^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0; next }
    /^identifier:/ { sub(/^identifier: */, ""); ident = $0; next }
    END { if (path != "" && ident == id) print path }
  ' | sort -u
}

unregister_other_copies() {
  local copy
  while IFS= read -r copy; do
    [[ -n "$copy" && "$copy" != "$APP" ]] || continue
    if "$LSREGISTER" -u "$copy" 2>/dev/null; then
      log "unregistered other copy: $copy"
    fi
  done < <(registered_copies)
}

# The Safari extension's switch as PluginKit reports it: "+" on, "-" off,
# blank never chosen. Read only; Safari › Settings › Extensions is the user's.
safari_extension_state() {
  local listing
  listing="$(pluginkit -m -i "$SAFARI_ID" 2>/dev/null || true)"
  printf '%s\n' "${listing:0:1}"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --open) OPEN=1 ;;
      --app) APP="${2:?--app needs a path}"; shift ;;
    esac
    shift
  done

  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

  [[ -d "$APP" ]] || { log "no app at $APP"; exit 0; }
  [[ "$(id -u)" -ne 0 ]] || { log "refusing to run as root"; exit 0; }
  log "setting up $APP"

  install_links
  unregister_other_copies
  log "Safari extension state: '$(safari_extension_state)'"

  if [[ "$OPEN" -eq 1 ]]; then
    # Wait for Installer to close (up to 15 minutes).
    local _
    for _ in $(seq 1 450); do
      pgrep -qx Installer || break
      sleep 2
    done
    sleep 0.5
    # -LatchkeyWelcome YES lasts this launch only: Latchkey opens its welcome
    # even when it has been set up before (an update or a reinstall).
    if open "$APP" --args -LatchkeyWelcome YES; then
      log "opened Latchkey's welcome"
    fi
  fi
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
