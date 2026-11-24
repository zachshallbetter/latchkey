#!/usr/bin/env python3
"""Register Pistachio's signed native helper locally. No browser permissions or extension stores are changed."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

HOST = "io.snackstud.pistachio"
FIREFOX_ID = "pistachio@snackstud.io"


def private_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError("refusing unsafe registration destination")
    if path.exists():
        current = json.loads(path.read_text())
        if path.name == HOST + ".json" and current.get("name") != HOST:
            raise ValueError("refusing to overwrite another native host")
    fd, temporary = tempfile.mkstemp(prefix=".pistachio-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Latchkey.app"))
    parser.add_argument("--chrome-id", action="append", default=[])
    parser.add_argument("--firefox", action="store_true")
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if any(not re.fullmatch(r"[a-p]{32}", value) for value in args.chrome_id):
        parser.error("Chrome IDs must contain exactly 32 letters a through p")
    if not args.chrome_id and not args.firefox:
        parser.error("select --chrome-id ID and/or --firefox")
    app = args.app.resolve()
    helper = app / "Contents/Helpers/pistachio-browser-host"
    # Check app and helper code before installing a manifest that executes the supplied path.
    for target in (app, helper):
        subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True, capture_output=True)
    details = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)], check=True, capture_output=True, text=True).stderr
    team = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", details, re.M)
    if not team:
        parser.error("the app needs an existing team signature")
    team = team.group(1)
    requirement = 'anchor apple generic and identifier "io.snackstud.pistachio.browser" and certificate leaf[subject.OU] = "' + team + '"'
    subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(helper)], check=True, capture_output=True)
    entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True).stdout
    groups = plistlib.loads(entitlements).get("com.apple.security.application-groups", [])
    group = team + ".io.snackstud.latchkey"
    if group not in groups:
        parser.error("app does not have its expected shared group")
    container = Path.home() / "Library/Group Containers" / group
    if container.is_symlink() or not container.is_dir():
        parser.error("open the signed app first to create its shared container")
    support = Path.home() / "Library/Application Support"
    paths = []
    if args.chrome_id:
        paths.append((support / "Google/Chrome/NativeMessagingHosts" / (HOST + ".json"),
                      {"allowed_origins": ["chrome-extension://" + value + "/" for value in sorted(set(args.chrome_id))]}))
    if args.firefox:
        paths.append((support / "Mozilla/NativeMessagingHosts" / (HOST + ".json"), {"allowed_extensions": [FIREFOX_ID]}))
    config_path = container / "browser-host-allowlist.json"
    if config_path.is_symlink():
        parser.error("refusing a linked allowlist")
    config = json.loads(config_path.read_text()) if config_path.exists() else {"chrome": [], "firefox": []}
    if args.chrome_id:
        config["chrome"] = [] if args.remove else sorted(set(args.chrome_id))
    if args.firefox:
        config["firefox"] = [] if args.remove else [FIREFOX_ID]
    for path, allowlist in paths:
        manifest = {"name": HOST, "description": "Pistachio browser connection", "path": str(helper), "type": "stdio", **allowlist}
        if args.dry_run:
            print(("Would remove " if args.remove else "Would register ") + str(path))
        elif args.remove:
            if path.is_symlink():
                parser.error("refusing to remove a linked manifest")
            if path.exists():
                if json.loads(path.read_text()).get("name") != HOST:
                    parser.error("refusing to remove another native host")
                path.unlink()
        else:
            private_json(path, manifest)
    if not args.dry_run:
        private_json(config_path, config)
    print("Registration preview complete" if args.dry_run else "Browser connection registration updated")


if __name__ == "__main__":
    main()
