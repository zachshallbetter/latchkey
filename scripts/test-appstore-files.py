#!/usr/bin/env python3
"""Fixture-only signed file access and revocation probe across three launches of the sandbox Debug app.

NSOpenPanel cannot be driven headlessly, so this harness stands in for it: it issues App Sandbox extension tokens
for temporary fixture paths (the mechanism the panel uses) and the app's SecurityScopedAccess takes it from there.
The panel click itself remains a manual test (docs/app-store.md). This script never touches real files, signs,
installs, launches the normal app or sets submission readiness.
"""
import argparse
import datetime
import ctypes
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

def debug_build(app):
    """True for a development-signed Debug build: only those compile the self-test entry points the probes use."""
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)], capture_output=True).stdout
    return b"com.apple.security.get-task-allow" in out


EXTENSION_CLASS = b"com.apple.app-sandbox.read-write"


def issue(path):
    function = ctypes.CDLL("/usr/lib/libSystem.dylib").sandbox_extension_issue_file
    function.restype = ctypes.c_char_p
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    token = function(EXTENSION_CLASS, os.fsencode(path), 0)
    if not token:
        raise RuntimeError("sandbox extension could not be issued")
    return token.decode()


def provenance(info):
    """Where the evidence came from: the signed build and the source commit the probes were built from."""
    commit = subprocess.run(["git", "-C", str(pathlib.Path(__file__).resolve().parent), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", str(pathlib.Path(__file__).resolve().parent), "status", "--porcelain", "--", ".", ":!docs/evidence"], capture_output=True, text=True).stdout.strip())
    return {"build": f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), development-signed sandbox Debug build",
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
    if info.get("LatchkeyDistributionChannel") != "app-store" or not debug_build(app):
        parser.error("only the sandbox experiment may run these probes")
    if subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True).returncode:
        parser.error("a valid development signature is required")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    phases, saved, failed = [], None, False
    # Fixtures live outside the app container, so access can only come from a granted extension.
    with tempfile.TemporaryDirectory(prefix="latchkey-file-probe-", dir="/private/tmp") as temporary:
        root = pathlib.Path(temporary).resolve()
        project, other = root / "project", root / "other"
        project.mkdir()
        other.mkdir()
        (project / ".env").write_text("KEY=fixture-value\n")
        (project / ".env").chmod(0o640)
        (other / ".env").write_text("OTHER=fixture-value\n")
        for phase in ("grant", "relaunch", "revoked"):
            request = {"root": str(root)}
            if phase == "grant":
                request.update(fileToken=issue(project / ".env"), folderToken=issue(project))
            elif saved is not None:
                request["saved"] = saved
            result = subprocess.run([str(binary), "--file-access-self-test", phase], input=json.dumps(request).encode(),
                                    capture_output=True, timeout=60)
            try:
                report = json.loads(result.stdout)
            except (UnicodeDecodeError, json.JSONDecodeError):
                parser.error(f"the {phase} launch returned no report; inspect the development build's signing")
            saved = report.pop("savedAccess", saved)   # records hold paths only; never written to evidence
            phases.append(report)
            failed = failed or not report.get("passed") or result.returncode != 0
            if failed:
                break
    report = {"passed": not failed and len(phases) == 3, "submissionReady": False, "phases": phases,
              "boundary": "Open panel selection is replaced by harness-issued sandbox extensions for fixture paths.",
              "notCovered": ["NSOpenPanel selection and the parent-folder prompt", "volume disconnect and reconnect", "moved references",
                             "stale bookmark refresh", "iCloud Drive or other file-provider folders", "Apple Distribution/TestFlight signing"]}
    report.update(provenance(info))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    for phase in phases:
        for item in phase.get("checks", []):
            print(("PASS: " if item["passed"] else "FAIL: ") + f"[{phase['phase']}] " + item["name"])
    print(f"Report: {args.report}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
