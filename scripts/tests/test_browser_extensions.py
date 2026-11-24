import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("browser_build", ROOT / "scripts/build-browser-extensions.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class BrowserPackageTests(unittest.TestCase):
    def test_browser_contexts_shared_artwork_and_repeatable_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            for target in ("chrome", "firefox"):
                result = builder.package(target, output)
                again = builder.package(target, output)
                self.assertEqual(result["sha256"], again["sha256"])
                popup = (output / target / "popup.html").read_text()
                self.assertIn("Pistachio for " + target.title(), popup)
                self.assertNotIn("Safari", popup)
                manifest = json.loads((output / target / "manifest.json").read_text())
                self.assertEqual(manifest["manifest_version"], 3)
                self.assertEqual(manifest["host_permissions"], ["<all_urls>"])
                if target == "chrome":
                    self.assertIn("service_worker", manifest["background"])
                    self.assertNotIn("browser_specific_settings", manifest)
                else:
                    self.assertNotIn("service_worker", manifest["background"])
                    self.assertEqual(manifest["browser_specific_settings"]["gecko"]["id"], builder.FIREFOX_ID)
                    self.assertNotIn("none", manifest["browser_specific_settings"]["gecko"]["data_collection_permissions"]["required"])
                for name in ("detector.js", "icon-48.png", "icon-96.png", "icon-128.png"):
                    self.assertEqual((output / target / name).read_bytes(), (ROOT / "App/Safari/Resources" / name).read_bytes())
                for name in ("content.js", "background.js", "popup.js"):
                    self.assertIn((ROOT / "App/Safari/Resources" / name).read_text(), (output / target / name).read_text())
                with zipfile.ZipFile(output / result["archive"]) as archive:
                    self.assertIn("manifest.json", archive.namelist())
                    self.assertNotIn(".pistachio-generated", archive.namelist())
                    self.assertTrue(all("/" not in name and not name.endswith((".pem", ".key")) for name in archive.namelist()))

    def test_unowned_directory_is_never_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "chrome"
            target.mkdir()
            marker = target / "user-data.txt"
            marker.write_text("fixture")
            with self.assertRaises(ValueError):
                builder.package("chrome", Path(directory))
            self.assertEqual(marker.read_text(), "fixture")


SETUP_SPEC = importlib.util.spec_from_file_location("browser_setup", ROOT / "scripts/setup-browser-connection.py")
setup = importlib.util.module_from_spec(SETUP_SPEC)
SETUP_SPEC.loader.exec_module(setup)


class BrowserRegistrationTests(unittest.TestCase):
    def test_registration_is_private_and_replaces_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / (setup.HOST + ".json")
            setup.private_json(path, {"name": setup.HOST, "path": "/fixture/first"})
            setup.private_json(path, {"name": setup.HOST, "path": "/fixture/second"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text())["path"], "/fixture/second")
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_registration_refuses_links_and_other_hosts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "original.json"
            target.write_text('{"name":"other-host"}')
            path = root / (setup.HOST + ".json")
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                setup.private_json(path, {"name": setup.HOST})
            path.unlink()
            path.write_text(target.read_text())
            with self.assertRaises(ValueError):
                setup.private_json(path, {"name": setup.HOST})
            self.assertEqual(target.read_text(), '{"name":"other-host"}')
