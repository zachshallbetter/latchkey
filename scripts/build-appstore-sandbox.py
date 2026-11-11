#!/usr/bin/env python3
"""Compile the full app in an experimental App Sandbox configuration; never install, archive or upload it.

XcodeGen runs against a source snapshot, so it cannot rewrite plists while another person edits the Safari target.
Unsigned builds prove compilation only. --signed uses existing development signing; it does not register app IDs,
create certificates or enable automatic provisioning updates.
"""
import argparse
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True, help="new directory for source, derived data and logs")
    parser.add_argument("--signed", action="store_true", help="use existing Apple Development signing; no account changes")
    args = parser.parse_args()
    out = args.output.resolve()
    if any(out.is_relative_to(ROOT / name) for name in ("App", "Sources", "Tests")) or out == ROOT:
        parser.error("output must be outside the source folders being copied")
    if out.exists():
        parser.error("output already exists; choose a new directory (existing builds are never deleted)")
    out.mkdir(parents=True)
    source = out / "source"
    source.mkdir()
    for name in ("App", "Sources", "Tests"):
        shutil.copytree(ROOT / name, source / name,
                        ignore=shutil.ignore_patterns(".git", ".build", "build", "*.xcodeproj", ".DS_Store", ".env", ".env.*"))
    shutil.copy2(ROOT / "Package.swift", source / "Package.swift")
    subprocess.run(["xcodegen", "generate", "--spec", str(source / "App/project.appstore.yml"),
                    "--project", str(source / "App")], check=True)
    command = ["xcodebuild", "-project", str(source / "App/LatchkeyAppStoreSandbox.xcodeproj"),
               "-scheme", "Latchkey", "-configuration", "Debug", "-destination", "generic/platform=macOS",
               "-derivedDataPath", str(out / "DerivedData"), "build"]
    if not args.signed:
        command += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
    register = pathlib.Path.home() / "Projects/_worktrees/.register/reg"
    if register.is_file() and register.stat().st_mode & 0o111:
        command = [str(register), "build", "--label", "latchkey-app-store", "--"] + command
    with (out / "build.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    print(f"Build log: {out / 'build.log'}")
    if result.returncode:
        print("Sandbox experiment did not compile.")
        return result.returncode
    app = out / "DerivedData/Build/Products/Debug/Latchkey.app"
    print(f"Built: {app}")
    print("Compilation is not proof of sandbox behavior or App Store readiness. Nothing was installed or uploaded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
