#!/usr/bin/env python3
"""Write the site's discovery files from its pages. Run before publishing; see docs/site.md.

- site/sitemap.xml: every page except 404.html, each with the date of its last change in Git (today when it has
  uncommitted changes).
- site/llms-full.txt: the text of every page's main content, for language-model tools, in the sitemap's order.
"""
import datetime, html, html.parser, pathlib, re, subprocess

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


class MainText(html.parser.HTMLParser):
    """The visible text of <main>, as plain lines: headings marked with #, list items with -, code kept as written.
    Navigation, scenes, the app window and other drawings (aria-hidden) are left out; their static text is example data."""

    BLOCK = {"p", "li", "h1", "h2", "h3", "h4", "pre", "tr", "summary", "figcaption", "dt", "dd"}

    def __init__(self):
        super().__init__()
        self.depth = 0  # inside <main>
        self.skip = 0  # inside something hidden
        self.stack = []
        self.lines, self.cur, self.pre = [], [], 0

    def flush(self, prefix=""):
        text = "".join(self.cur)
        text = text if self.pre else re.sub(r"\s+", " ", text).strip()
        if text:
            self.lines.append(prefix + text)
        self.cur = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "main":
            self.depth += 1
        if not self.depth or tag in ("br", "img", "input", "meta", "link", "hr", "source", "wbr"):
            return
        hidden = (a.get("aria-hidden") == "true" or "hidden" in a or tag in ("script", "style", "button", "svg", "nav", "aside")
                  or "toc" in (a.get("class") or "").split())
        self.stack.append((tag, hidden))
        if hidden:
            self.skip += 1
        if self.skip:
            return
        if tag in self.BLOCK:
            self.flush()
        if tag == "pre":
            self.pre += 1

    def handle_endtag(self, tag):
        if tag == "main":
            self.flush()
            self.depth -= 1
            return
        if not self.depth or not self.stack:
            return
        while self.stack:
            t, hidden = self.stack.pop()
            if hidden:
                self.skip -= 1
            elif not self.skip and t in self.BLOCK:
                prefix = {"h1": "# ", "h2": "## ", "h3": "### ", "h4": "#### ", "li": "- "}.get(t, "")
                if t == "pre":
                    self.cur = ["```\n"] + self.cur + ["\n```"]
                self.flush(prefix)
                if t == "pre":
                    self.pre -= 1
            if t == tag:
                break

    def handle_data(self, data):
        if self.depth and not self.skip:
            self.cur.append(data)


pages = sorted(p for p in SITE.rglob("*.html") if p.name != "404.html")
lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
lines += [f"  <url><loc>{url(p)}</loc><lastmod>{last_change(p)}</lastmod></url>" for p in pages]
lines.append("</urlset>")
(SITE / "sitemap.xml").write_text("\n".join(lines) + "\n")

full = ["# Latchkey: the full text of latchkey.snackstud.io", "",
        "Every page's main content as plain text. The curated index is llms.txt. Scenes and the app window show example data and are left out.", ""]
for p in pages:
    title = re.search(r"<title>(.*?)</title>", p.read_text(), re.S).group(1)
    parser = MainText()
    parser.feed(p.read_text())
    full += ["---", "", f"Page: {html.unescape(title)}", f"URL: {url(p)}", ""]
    full += parser.lines + [""]
(SITE / "llms-full.txt").write_text("\n".join(full))
print(f"wrote {len(pages)} URLs to site/sitemap.xml and site/llms-full.txt")
