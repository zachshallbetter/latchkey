import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import release_notes  # noqa: E402

SAMPLE = """# Changelog

## 0.4.0 (2026-11-18)

### App
- Latchkey locks when it opens, after 5 minutes
  in the background, and on sleep.
- `lk push` asks; **Use Password…** opens the sheet. <script>x</script>

## 0.3.1 (2026-11-13)

### Site
- A [link](https://example.test/a) and a [bad one](javascript:alert(1)).
"""


class ReleaseNotesTests(unittest.TestCase):
    def test_parse_joins_continuation_lines(self):
        r = release_notes.release(SAMPLE, "0.4.0")
        self.assertEqual(r["date"], "2026-11-18")
        self.assertEqual(r["sections"][0]["items"][0], "Latchkey locks when it opens, after 5 minutes in the background, and on sleep.")
        self.assertIsNone(release_notes.release(SAMPLE, "9.9.9"))

    def test_html_escapes_and_keeps_only_web_links(self):
        out = release_notes.release_html(release_notes.release(SAMPLE, "0.4.0"))
        self.assertIn("<code>lk push</code>", out)
        self.assertIn("<b>Use Password…</b>", out)
        self.assertIn("&lt;script&gt;", out)
        self.assertNotIn("<script>", out)
        links = release_notes.release_html(release_notes.release(SAMPLE, "0.3.1"))
        self.assertIn('<a href="https://example.test/a">link</a>', links)
        self.assertNotIn('href="javascript', links)

    def test_appcast_embeds_the_notes_and_refuses_a_version_without_any(self):
        with tempfile.TemporaryDirectory() as d:
            changelog = pathlib.Path(d) / "CHANGELOG.md"
            changelog.write_text(SAMPLE)
            appcast = pathlib.Path(d) / "appcast.xml"
            base = [sys.executable, str(SCRIPTS / "update-appcast.py"), "--appcast", str(appcast), "--build", "7",
                    "--min-os", "15.0", "--signature", 'sparkle:edSignature="c2ln" length="10"', "--changelog", str(changelog)]
            ok = subprocess.run(base + ["--version", "0.4.0"], capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            item = ET.parse(appcast).getroot().find("channel/item")
            self.assertIn("Latchkey locks when it opens", item.findtext("description"))
            refused = subprocess.run(base + ["--version", "9.9.9"], capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("no notes", refused.stderr)

    def test_the_repository_changelog_has_the_version_being_built(self):
        root = SCRIPTS.parent
        project = (root / "App/project.yml").read_text()
        version = project.split('MARKETING_VERSION: "')[1].split('"')[0]
        r = release_notes.release((root / "CHANGELOG.md").read_text(), version)
        self.assertIsNotNone(r, f"CHANGELOG.md has no ## {version}")
        self.assertTrue(any(s["items"] for s in r["sections"]))


if __name__ == "__main__":
    unittest.main()
