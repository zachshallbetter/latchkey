import copy
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "appstore-preflight.py"
spec = importlib.util.spec_from_file_location("appstore_preflight", SCRIPT)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def test_submission_never_accepts_a_static_build_as_runtime_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            readiness = {"scope": "full-functionality", "submissionEnabled": True,
                         "metadata": {"supportURL": "https://example.test/support", "privacyPolicyURL": "https://example.test/privacy",
                                      "reviewContactConfirmed": True, "exportComplianceReviewed": True},
                         "runtimeGates": {name: {"status": "passed", "evidence": ["missing.md"]} for name in preflight.GATES}}
            self.assertEqual(len(preflight.submission_errors(readiness, root)), len(preflight.GATES))
            (root / "evidence.md").write_text("Fixture only; not real release evidence.")
            for gate in readiness["runtimeGates"].values():
                gate["evidence"] = ["evidence.md"]
            self.assertEqual(preflight.submission_errors(readiness, root), [])
            readiness["submissionEnabled"] = False
            self.assertTrue(preflight.submission_errors(readiness, root))
            readiness["runtimeGates"]["commandExecutionProxyAndAWS"]["evidence"] = ["../outside.md"]
            self.assertTrue(any("repository file" in e for e in preflight.submission_errors(readiness, root)))

    def test_exact_entitlement_inventory_rejects_extra_permissions_and_false_values(self):
        entitlements = {key: True for key in preflight.ALLOWED}
        entitlements["keychain-access-groups"] = ["TEAM.fixture"]
        entitlements["com.apple.security.application-groups"] = ["TEAM.fixture"]
        self.assertEqual(preflight.entitlement_errors(entitlements), [])
        unsafe = copy.deepcopy(entitlements)
        unsafe["com.apple.security.temporary-exception.files.home-relative-path.read-write"] = ["/"]
        self.assertTrue(preflight.entitlement_errors(unsafe))
        entitlements["com.apple.security.app-sandbox"] = False
        self.assertTrue(preflight.entitlement_errors(entitlements))

    def test_privacy_changes_require_a_new_audit(self):
        manifest = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
                    "NSPrivacyAccessedAPITypes": [
                        {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
                        {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1", "3B52.1"]}]}
        self.assertEqual(preflight.privacy_errors(manifest), [])
        manifest["NSPrivacyTrackingDomains"] = ["tracking.example.test"]
        self.assertTrue(preflight.privacy_errors(manifest))
        manifest["NSPrivacyAccessedAPITypes"] = []
        self.assertTrue(preflight.privacy_errors(manifest))

    def test_store_bundle_rejects_sparkle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / "Latchkey.app"
            (app / "Contents/Resources").mkdir(parents=True)
            (app / "Contents/Resources/PrivacyInfo.xcprivacy").write_text("")
            info = {"CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "CFBundleIdentifier": "io.example.app"}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            self.assertFalse(any("Sparkle" in e for e in preflight.bundle_errors(app, dev=True, submission=False)))
            (app / "Contents/Frameworks/Sparkle.framework").mkdir(parents=True)
            self.assertTrue(any("Sparkle" in e for e in preflight.bundle_errors(app, dev=True, submission=False)))
            (app / "Contents/Frameworks/Sparkle.framework").rmdir()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({**info, "SUFeedURL": "https://example.test/appcast.xml"}))
            self.assertTrue(any("Sparkle" in e for e in preflight.bundle_errors(app, dev=True, submission=False)))


if __name__ == "__main__":
    unittest.main()
