#!/usr/bin/env python3
"""Run the fixture-only vault and history probe from a development-signed experimental app, with no UI.

It uses a unique fixture service in the app's access group, never synchronizes, and never queries the real
"latchkey" items. This is a component probe: it never sets submission readiness.
"""
import argparse
import datetime
import json
import pathlib
import plistlib
import subprocess


def provenance(info):
    """Where the evidence came from: the signed build and the source commit the probes were built from."""
    commit = subprocess.run(["git", "-C", str(pathlib.Path(__file__).resolve().parent), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", str(pathlib.Path(__file__).resolve().parent), "status", "--porcelain", "--", ".", ":!docs/evidence"], capture_output=True, text=True).stdout.strip())
    return {"build": f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), development-signed sandbox Debug experiment",
            "sourceCommit": commit, "sourceClean": not dirty, "verifiedOn": datetime.date.today().isoformat()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        parser.error("report already exists; use a new filename")
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("LatchkeyDistributionChannel") != "app-store-sandbox-experiment":
        parser.error("only the sandbox experiment may run these probes")
    if subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True).returncode:
        parser.error("a valid development signature is required")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    result = subprocess.run([str(binary), "--vault-self-test"], input=b"", capture_output=True, timeout=60)
    try:
        report = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError):
        parser.error("the probe did not return a report; inspect the development build's signing and keychain entitlements")
    report.update(provenance(info))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    for item in report.get("checks", []):
        print(("PASS: " if item["passed"] else "FAIL: ") + item["name"])
    print(f"Report: {args.report}")
    return 0 if report.get("passed") and result.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
