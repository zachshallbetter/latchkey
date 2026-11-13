#!/usr/bin/env python3
"""Check sandbox configuration, a built bundle, or full submission gates without changing Apple accounts.

Default: source configuration only. --app inspects a built bundle; --dev permits an unsigned compilation artifact.
--submission requires signed artifacts and recorded runtime evidence. No command uploads or approves a release.
"""
import argparse
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWED = {
    "com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope", "com.apple.security.network.client",
    "com.apple.security.network.server", "com.apple.security.application-groups", "keychain-access-groups",
}
GATES = {
    "vaultAndHistory", "signedFileAccessAndRevocation", "authenticatedCLITransportAndCallerIdentity",
    "commandExecutionProxyAndAWS", "nativeRemotePushes", "directToStoreMigrationAndSync",
    "safariIntegration", "cleanMacTestFlightReviewFlow",
}


def load_plist(path):
    return plistlib.loads(path.read_bytes())


def entitlement_errors(values):
    errors = []
    if set(values) != ALLOWED:
        errors.append(f"sandbox entitlement set differs: extra={sorted(set(values) - ALLOWED)}, missing={sorted(ALLOWED - set(values))}")
    for key in ALLOWED - {"com.apple.security.application-groups", "keychain-access-groups"}:
        if values.get(key) is not True:
            errors.append(f"{key} must be enabled")
    for key in ("com.apple.security.application-groups", "keychain-access-groups"):
        if not isinstance(values.get(key), list) or not values[key] or any(not isinstance(v, str) or not v for v in values[key]):
            errors.append(f"{key} must contain explicit identifiers")
    return errors


def privacy_errors(manifest, expected=None):
    errors = []
    if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains") != []:
        errors.append("privacy manifest must declare no tracking or tracking domains")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        errors.append("collection changed; review the app privacy declaration before proceeding")
    reasons = {row.get("NSPrivacyAccessedAPIType"): row.get("NSPrivacyAccessedAPITypeReasons")
               for row in manifest.get("NSPrivacyAccessedAPITypes", [])}
    if expected is None:
        expected = {"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                    "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"]}
    if reasons != expected:
        errors.append("required-reason inventory differs from the documented app API audit")
    return errors


def submission_errors(readiness, root):
    errors = []
    if readiness.get("scope") != "full-functionality":
        errors.append("full-functionality scope must be preserved")
    if readiness.get("submissionEnabled") is not True:
        errors.append("submission is disabled while the sandbox redesign is incomplete")
    metadata = readiness.get("metadata", {})
    for name in ("supportURL", "privacyPolicyURL"):
        parsed = urllib.parse.urlsplit(metadata.get(name) or "")
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            errors.append(f"{name} needs a public HTTPS URL without credentials")
    for name in ("reviewContactConfirmed", "exportComplianceReviewed"):
        if metadata.get(name) is not True:
            errors.append(f"owner review needed: {name}")
    gates = readiness.get("runtimeGates", {})
    for name in sorted(GATES):
        gate = gates.get(name, {})
        evidence = gate.get("evidence", [])
        if gate.get("status") != "passed" or not isinstance(evidence, list) or not evidence:
            errors.append(f"runtime evidence missing: {name}")
            continue
        for entry in evidence:
            if not isinstance(entry, str):
                errors.append(f"invalid evidence path: {name}")
                continue
            path = (root / entry).resolve()
            if not path.is_relative_to(root.resolve()) or not path.is_file():
                errors.append(f"runtime evidence is not a repository file: {name}")
    return errors


def source_errors(root):
    errors = entitlement_errors(load_plist(root / "App/AppStore/Latchkey.entitlements"))
    errors += privacy_errors(load_plist(root / "App/Privacy/App/PrivacyInfo.xcprivacy"))
    # The extension reaches only the broker socket and reads no timestamps or preferences: no required-reason API.
    errors += [f"Safari: {e}" for e in privacy_errors(load_plist(root / "App/Privacy/Safari/PrivacyInfo.xcprivacy"), expected={})]
    info = load_plist(root / "App/AppStore/Info.plist")
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != ("$(MARKETING_VERSION)", "$(CURRENT_PROJECT_VERSION)"):
        errors.append("store version and build must come from Xcode settings")
    if not info.get("NSHumanReadableCopyright"):
        errors.append("copyright is missing")
    if "ITSAppUsesNonExemptEncryption" in info:
        errors.append("the experiment must not pre-answer the owner's encryption export declaration")
    with tempfile.TemporaryDirectory() as temp:
        resolved = pathlib.Path(temp) / "spec.json"
        subprocess.run(["xcodegen", "dump", "--spec", str(root / "App/project.appstore.yml"), "--type", "json",
                        "--file", str(resolved), "--quiet"], check=True)
        spec = json.loads(resolved.read_text())
    target = spec["targets"]["Latchkey"]
    if target["entitlements"]["properties"] != load_plist(root / "App/AppStore/Latchkey.entitlements"):
        errors.append("resolved Xcode entitlements differ from their checked-in source")
    if "Sparkle" in spec.get("packages", {}) or any("Sparkle" in str(d) for d in target.get("dependencies", [])) \
            or any(key.startswith("SU") for key in info):
        errors.append("the store build must not include Sparkle; it updates through the App Store")
    settings = target["settings"]["base"]
    if settings.get("ENABLE_APP_SANDBOX") is not True or "LATCHKEY_APP_STORE" not in settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""):
        errors.append("sandbox or experimental compilation condition is missing")
    return errors


def bundle_errors(app, dev, submission, inspector=None):
    errors = []
    bundles = [app] + sorted((app / "Contents/PlugIns").glob("*.appex"))
    main = load_plist(app / "Contents/Info.plist")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", str(main.get(key, ""))):
            errors.append(f"unresolved or invalid built {key}")
    if (app / "Contents/Frameworks/Sparkle.framework").exists() or any(key.startswith("SU") for key in main):
        errors.append("Sparkle is present in the store bundle")
    main_team = None
    for bundle in bundles:
        info = load_plist(bundle / "Contents/Info.plist")
        if any(info.get(k) != main.get(k) for k in ("CFBundleShortVersionString", "CFBundleVersion")):
            errors.append(f"embedded version/build mismatch: {bundle.name}")
        if bundle != app and not info.get("CFBundleIdentifier", "").startswith(main["CFBundleIdentifier"] + "."):
            errors.append(f"embedded bundle ID is outside its containing app: {bundle.name}")
        manifest = bundle / "Contents/Resources/PrivacyInfo.xcprivacy"
        if not manifest.is_file():
            errors.append(f"privacy manifest missing: {bundle.name}")
        if not dev:
            try:
                signature = json.loads(subprocess.check_output([str(inspector), str(bundle)]))
            except (ValueError, subprocess.CalledProcessError):
                errors.append(f"cannot inspect signed entitlements: {bundle.name}")
                continue
            entitlements = signature.get("entitlements", {})
            if entitlements.get("com.apple.security.app-sandbox") is not True:
                errors.append(f"signed sandbox entitlement absent: {bundle.name}")
            if entitlements.get("com.apple.security.get-task-allow") or any("temporary-exception" in key for key in entitlements):
                errors.append(f"debugging or temporary-exception entitlement: {bundle.name}")
            team = signature.get("teamIdentifier")
            if bundle == app:
                main_team = team
            elif not team or team != main_team:
                errors.append(f"embedded signing team mismatch: {bundle.name}")
            if submission and not any(name.startswith(("Apple Distribution:", "3rd Party Mac Developer Application:"))
                                      for name in signature.get("certificateCommonNames", [])):
                errors.append(f"not signed for App Store distribution: {bundle.name}")
            if not signature.get("valid"):
                errors.append(f"signature invalid: {bundle.name}")
    if not (app / "Contents/Resources/Assets.car").is_file():
        errors.append("compiled icon assets missing")
    if submission and main.get("LatchkeyDistributionChannel") != "app-store":
        errors.append("a sandbox experiment cannot be submitted as a release")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=ROOT)
    parser.add_argument("--app", type=pathlib.Path)
    parser.add_argument("--dev", action="store_true")
    parser.add_argument("--submission", action="store_true")
    args = parser.parse_args()
    if args.submission and (not args.app or args.dev):
        parser.error("submission checks require a signed --app and do not permit --dev")
    try:
        errors = source_errors(args.root)
        if args.app:
            with tempfile.TemporaryDirectory() as temp:
                inspector = pathlib.Path(temp) / "inspect-signature"
                if not args.dev:
                    subprocess.run(["xcrun", "swiftc", str(args.root / "scripts/inspect-code-signature.swift"),
                                    "-o", str(inspector)], check=True)
                errors += bundle_errors(args.app, args.dev, args.submission, inspector)
        if args.submission:
            readiness = json.loads((args.root / "packaging/app-store/readiness.json").read_text())
            errors += submission_errors(readiness, args.root)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        errors = [f"preflight could not complete: {exc}"]
    for error in errors:
        print(f"FAIL: {error}")
    print("FAIL" if errors else "PASS: requested static checks; runtime and Apple review remain separate gates")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
