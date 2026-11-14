#!/usr/bin/env python3
"""Build the Mac App Store submission: a Release archive of the sandboxed store variant, exported for App Store
Connect as a signed installer package, then checked with appstore-preflight.py. It never uploads: upload the package
with Transporter or Xcode's Organizer, signed in as yourself (docs/app-store.md, "Submitting").

  python3 scripts/release-appstore.py --output build/appstore/0.3.0

Needs, once per team: an Apple Distribution certificate and a Mac Installer Distribution certificate, and App IDs for
io.snackstud.latchkey and io.snackstud.latchkey.safari. Automatic signing (-allowProvisioningUpdates) creates the
App Store provisioning profiles; it may also create a missing certificate or App ID in your account, so run this
yourself. XcodeGen runs against a source snapshot, as in build-appstore-sandbox.py, so no plist in the checkout is
rewritten.
"""
import argparse
import pathlib
import plistlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def run(command, log):
    register = pathlib.Path.home() / "Projects/_worktrees/.register/reg"
    if register.is_file() and register.stat().st_mode & 0o111:
        command = [str(register), "build", "--label", "latchkey-app-store-release", "--"] + command
    with log.open("a") as out:
        out.write("$ " + " ".join(command) + "\n")
        out.flush()
        return subprocess.run(command, stdout=out, stderr=subprocess.STDOUT).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=pathlib.Path, required=True, help="new directory for the snapshot, archive and package")
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists():
        parser.error("output already exists; choose a new directory")
    project = (ROOT / "App/project.yml").read_text()
    team = re.search(r'DEVELOPMENT_TEAM:\s*"?([A-Z0-9]+)', project).group(1)
    version = re.search(r'MARKETING_VERSION:\s*"?([0-9.]+)', project).group(1)

    out.mkdir(parents=True)
    log = out / "build.log"
    source = out / "source"
    source.mkdir()
    for name in ("App", "Sources", "Tests"):
        shutil.copytree(ROOT / name, source / name,
                        ignore=shutil.ignore_patterns(".git", ".build", "build", "*.xcodeproj", ".DS_Store", ".env", ".env.*"))
    shutil.copy2(ROOT / "Package.swift", source / "Package.swift")
    subprocess.run(["xcodegen", "generate", "--spec", str(source / "App/project.appstore.yml"), "--project", str(source / "App")],
                   check=True)

    archive = out / "Latchkey.xcarchive"
    print(f"Archiving Latchkey {version} for the Mac App Store (team {team})")
    if run(["xcodebuild", "-project", str(source / "App/LatchkeyAppStoreSandbox.xcodeproj"), "-scheme", "Latchkey",
            "-configuration", "Release", "-destination", "generic/platform=macOS", "-archivePath", str(archive),
            "-derivedDataPath", str(out / "DerivedData"), "-allowProvisioningUpdates", f"DEVELOPMENT_TEAM={team}",
            "archive"], log):
        print(f"Archive failed; see {log}")
        return 1

    options = out / "ExportOptions.plist"
    options.write_bytes(plistlib.dumps({"method": "app-store-connect", "destination": "export", "teamID": team,
                                        "signingStyle": "automatic", "uploadSymbols": True}))
    export = out / "export"
    print("Exporting for App Store Connect")
    if run(["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportPath", str(export),
            "-exportOptionsPlist", str(options), "-allowProvisioningUpdates"], log):
        print(f"Export failed; see {log}")
        return 1
    packages = list(export.glob("*.pkg"))
    if len(packages) != 1:
        print(f"Expected one installer package in {export}, found {len(packages)}")
        return 1

    app = archive / "Products/Applications/Latchkey.app"
    # Files from a download carry com.apple.quarantine, which App Store Connect refuses (since February 2025).
    quarantined = subprocess.run(["xattr", "-r", "-l", str(app)], capture_output=True, text=True).stdout
    if "com.apple.quarantine" in quarantined:
        print("The archived app carries com.apple.quarantine; remove it (xattr -r -d com.apple.quarantine) and rebuild")
        return 1
    print("Checking the signed app")
    check = subprocess.run(["python3", str(ROOT / "scripts/appstore-preflight.py"), "--app", str(app)])
    print(f"\nPackage: {packages[0]}")
    print("Upload it with Transporter or Xcode's Organizer. Nothing was uploaded.")
    return check.returncode


if __name__ == "__main__":
    raise SystemExit(main())
