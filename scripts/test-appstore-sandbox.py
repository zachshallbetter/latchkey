#!/usr/bin/env python3
"""Run fixture-only native sandbox probes from a development-signed experimental app, with no UI or vault access.

This is a component probe, not the full-functionality acceptance suite. It never sets submission readiness.
"""
import argparse
import json
import pathlib
import subprocess

def debug_build(app):
    """True for a development-signed Debug build: only those compile the self-test entry points the probes use."""
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)], capture_output=True).stdout
    return b"com.apple.security.get-task-allow" in out



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        parser.error("report already exists; use a new filename")
    app = args.app.resolve()
    import plistlib
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("LatchkeyDistributionChannel") != "app-store" or not debug_build(app):
        parser.error("only the sandbox experiment may run these probes")
    if subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True).returncode:
        parser.error("a valid development signature is required")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    result = subprocess.run([str(binary), "--sandbox-self-test"], input=b"", capture_output=True, timeout=30)
    try:
        report = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError):
        parser.error("the probe did not return a report; inspect the development build's signing and sandbox logs")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"Report: {args.report}")
    print("Component probes passed; full-functionality gates remain pending." if report.get("passed") and result.returncode == 0
          else "Component probes failed; this is not a release candidate.")
    return 0 if report.get("passed") and result.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
