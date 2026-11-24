"""The app's stored identifiers stay the same through a rename (zachshallbetter/latchkey#121).

Bundle IDs, access groups, the App Group and the Pro product ID decide which Keychain items, containers and
purchases a build can reach. A build that changes any of them can't read what an earlier build stored, and App
Store Connect can't rename a bundle or product ID. Only display names change. See "Stored identifiers" in
docs/development.md; the Swift-side names are pinned in Tests/LatchkeyCoreTests/StoredIdentifierTests.swift.
"""

import pathlib
import plistlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "App"
APP_GROUP = "$(TeamIdentifierPrefix)io.snackstud.latchkey"
ACCESS_GROUP = "$(AppIdentifierPrefix)io.snackstud.latchkey"
PREVIOUS_ACCESS_GROUP = "$(AppIdentifierPrefix)io.latchkey.shared"


def text(path):
    return (ROOT / path).read_text(encoding="utf-8")


def plist(path):
    with open(ROOT / path, "rb") as f:
        return plistlib.load(f)


class StoredIdentifierTests(unittest.TestCase):
    def test_developer_id_project_keeps_bundle_ids_and_groups(self):
        project = text("App/project.yml")
        for line in (
            "PRODUCT_BUNDLE_IDENTIFIER: io.snackstud.latchkey\n",
            "PRODUCT_BUNDLE_IDENTIFIER: io.snackstud.latchkey.safari\n",
            f"LatchkeyAccessGroup: {ACCESS_GROUP}\n",
            f"LatchkeyPreviousAccessGroup: {PREVIOUS_ACCESS_GROUP}\n",
            f"LatchkeyAppGroup: {APP_GROUP}\n",
        ):
            self.assertIn(line, project)

    def test_app_store_project_keeps_groups(self):
        project = text("App/project.appstore.yml")
        self.assertIn(f"LatchkeyAccessGroup: {ACCESS_GROUP}\n", project)
        self.assertIn(f"LatchkeyAppGroup: {APP_GROUP}\n", project)

    def test_entitlements_keep_groups(self):
        app = plist("App/Latchkey/Latchkey.entitlements")
        self.assertEqual(app["com.apple.security.application-groups"], [APP_GROUP])
        self.assertEqual(app["keychain-access-groups"], [ACCESS_GROUP, PREVIOUS_ACCESS_GROUP])
        store = plist("App/AppStore/Latchkey.entitlements")
        self.assertEqual(store["com.apple.security.application-groups"], [APP_GROUP])
        self.assertEqual(store["keychain-access-groups"], [ACCESS_GROUP])
        safari = plist("App/Safari/Safari.entitlements")
        self.assertEqual(safari["com.apple.security.application-groups"], [APP_GROUP])

    def test_info_plists_keep_groups(self):
        for path in ("App/Latchkey/Info.plist", "App/AppStore/Info.plist"):
            info = plist(path)
            self.assertEqual(info["LatchkeyAccessGroup"], ACCESS_GROUP, path)
            self.assertEqual(info["LatchkeyAppGroup"], APP_GROUP, path)
        self.assertEqual(plist("App/Latchkey/Info.plist")["LatchkeyPreviousAccessGroup"], PREVIOUS_ACCESS_GROUP)
        self.assertEqual(plist("App/AppStore/Safari.Info.plist")["LatchkeyAppGroup"], APP_GROUP)

    def test_pro_product_id_is_unchanged(self):
        self.assertIn('static let productID = "io.snackstud.latchkey.pro"', text("App/Latchkey/ProEntitlement.swift"))
        self.assertIn('"productID" : "io.snackstud.latchkey.pro"', text("App/AppStore/Latchkey.storekit"))

    def test_cli_signing_identifier_is_unchanged(self):
        for path in ("scripts/release.sh", "scripts/install.sh"):
            self.assertIn("--identifier io.snackstud.latchkey.cli ", text(path), path)

    def test_safari_extension_messages_the_same_app(self):
        popup = text("App/Safari/Resources/popup.js")
        background = text("App/Safari/Resources/background.js")
        self.assertIn('sendNativeMessage("io.snackstud.latchkey"', popup)
        self.assertRegex(background, re.compile(r'APP\s*=\s*"io\.snackstud\.latchkey"'))


if __name__ == "__main__":
    unittest.main()
