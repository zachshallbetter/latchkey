#!/usr/bin/env python3
"""Write site/changelog.html from CHANGELOG.md, and point the site at it.

- site/changelog.html: every released version, newest first, each under an `id="vVERSION"` heading, in the layout of
  the terms page (its head, header and footer are reused; only the article is generated). "Unreleased" is left out.
- Every page's links to the changelog on GitHub become links to that page.
- Every `<a data-latest-version href="…changelog.html#v…">` (the home page's install note) names the newest release.

Run it after dating a release in CHANGELOG.md, then scripts/social-images.py and scripts/discovery.py.
"""
import datetime
import html
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release_notes  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
GITHUB_CHANGELOG = "https://github.com/zachshallbetter/latchkey/blob/main/CHANGELOG.md"
TITLE = "Changelog"
DESCRIPTION = "What changed in each version of Latchkey, newest first. The app shows the same notes after it updates."


def long_date(iso):
    try:
        return datetime.date.fromisoformat(iso).strftime("%-d %B %Y")
    except (TypeError, ValueError):
        return iso or ""


def article(releases):
    latest = releases[0]
    parts = [
        "    <article class=\"doc\">",
        f"      <h1>{TITLE}</h1>",
        "      <p class=\"lede\">What changed in each version of Latchkey, newest first. The app shows the same notes once "
        "after it updates, and again from <b>Latchkey › What's New in Latchkey…</b>.</p>",
        f"      <p class=\"fine\">Latest: <a href=\"#v{html.escape(latest['version'])}\">{html.escape(latest['version'])}</a>, "
        f"{html.escape(long_date(latest['date']))}. <a href=\"https://github.com/zachshallbetter/latchkey/releases/latest\">Download</a>.</p>",
    ]
    for r in releases:
        v = html.escape(r["version"])
        parts.append(f"\n      <h2 id=\"v{v}\">{v}</h2>")
        if r["date"]:
            parts.append(f"      <p class=\"fine\">{html.escape(long_date(r['date']))}</p>")
        parts.append(release_notes.release_html(r))
    parts.append("    </article>")
    return "\n".join(parts)


def page(releases):
    template = (SITE / "terms.html").read_text()
    old_desc = re.search(r'<meta name="description" content="([^"]*)"', template).group(1)
    # Only the head names the page (title, canonical URL, social image, structured data); the header and footer stay
    # as they are, with their own link to the terms.
    cut = template.index("<body")
    head = template[:cut].replace("terms.html", "changelog.html").replace("social/terms.jpg", "social/changelog.jpg")
    head = head.replace("Terms of use", TITLE).replace(old_desc, html.escape(DESCRIPTION, quote=True))
    head = head.replace('"name": "Terms"', f'"name": "{TITLE}"')
    body = template[cut:].replace('<a href="terms.html" aria-current="page">', '<a href="terms.html">')
    for link in (f'<a href="{GITHUB_CHANGELOG}">', '<a href="changelog.html">'):
        body = body.replace(link, '<a href="changelog.html" aria-current="page">')
    s = head.replace(html.unescape(old_desc), DESCRIPTION) + body
    a, b = s.index('    <article class="doc">'), s.index("    </article>") + len("    </article>")
    return s[:a] + article(releases) + s[b:]


def link_pages(latest):
    changed = []
    for f in sorted(SITE.rglob("*.html")):
        rel = f.relative_to(SITE)
        prefix = "/" if f.name == "404.html" else "../" * (len(rel.parts) - 1)
        s = f.read_text()
        t = s.replace(f'href="{GITHUB_CHANGELOG}"', f'href="{prefix}changelog.html"')
        t = re.sub(r'(<a data-latest-version href=")([^"#]*changelog\.html)#v[^"]*(">)[^<]*(</a>)',
                   lambda m: f"{m.group(1)}{m.group(2)}#v{latest}{m.group(3)}{latest}{m.group(4)}", t)
        if t != s:
            f.write_text(t)
            changed.append(str(rel))
    return changed


def main():
    releases = [r for r in release_notes.parse((ROOT / "CHANGELOG.md").read_text()) if r["version"] != "Unreleased"]
    if not releases:
        sys.exit("CHANGELOG.md has no released version")
    (SITE / "changelog.html").write_text(page(releases))
    changed = link_pages(releases[0]["version"])
    print(f"wrote site/changelog.html ({len(releases)} versions, latest {releases[0]['version']}); updated {len(changed)} pages")


if __name__ == "__main__":
    main()
