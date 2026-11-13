#!/usr/bin/env python3
"""Write site/sitemap.xml: every page except 404.html, each with the date of its last change in Git (today when it
has uncommitted changes). Run before publishing the site; see docs/site.md."""
import datetime, pathlib, subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
BASE = "https://latchkey.snackstud.io/"


def last_change(path):
    rel = path.relative_to(ROOT).as_posix()
    dirty = subprocess.run(["git", "status", "--porcelain", "--", rel], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    if dirty:
        return datetime.date.today().isoformat()
    out = subprocess.run(["git", "log", "-1", "--format=%cs", "--", rel], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    if not out:
        raise SystemExit(f"{rel} has no Git history; commit it first")
    return out


def url(path):
    rel = path.relative_to(SITE).as_posix()
    if rel == "index.html":
        return BASE
    if rel.endswith("/index.html"):
        return BASE + rel[: -len("index.html")]
    return BASE + rel


pages = sorted(p for p in SITE.rglob("*.html") if p.name != "404.html")
lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
lines += [f"  <url><loc>{url(p)}</loc><lastmod>{last_change(p)}</lastmod></url>" for p in pages]
lines.append("</urlset>")
(SITE / "sitemap.xml").write_text("\n".join(lines) + "\n")
print(f"wrote {len(pages)} URLs to site/sitemap.xml")
