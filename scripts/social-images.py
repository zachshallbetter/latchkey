#!/usr/bin/env python3
"""Render each page's social card into site/social/<page>.jpg from scripts/og-image.html, with headless Chrome, and
point the page's og:image, twitter:image and JSON-LD at it. The home page keeps site/og.png. Run after changing a
page's title or description; see docs/site.md."""
import html, json, pathlib, re, subprocess, tempfile, urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
BASE = "https://latchkey.snackstud.io/"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
EYEBROW = {"developers": "Docs", "guides": "Guide"}


def card_text(page, text):
    title = html.unescape(re.search(r"<title>(.*?)</title>", text, re.S).group(1)).split(" · ")[0]
    desc = html.unescape(re.search(r'<meta name="description" content="([^"]*)"', text).group(1))
    sub = desc if len(desc) <= 110 else desc[: desc.rfind(" ", 0, 107)] + "…"
    eyebrow = EYEBROW.get(page.parent.name, "Latchkey")
    head, _, rest = title.partition(": ")
    if rest and len(head) <= 24:  # "Pricing: free for good…" → eyebrow "Pricing", title the rest
        eyebrow, title = head, (rest if "://" in rest.split(" ")[0] else rest[0].upper() + rest[1:])
    return eyebrow, title, sub


out = SITE / "social"
out.mkdir(exist_ok=True)
pages = sorted(p for p in SITE.rglob("*.html") if p.name != "404.html" and p != SITE / "index.html")
with tempfile.TemporaryDirectory() as tmp:
    for page in pages:
        text = page.read_text()
        eyebrow, title, sub = card_text(page, text)
        slug = page.relative_to(SITE).as_posix().replace("/", "-").removesuffix(".html")
        png = pathlib.Path(tmp) / f"{slug}.png"
        query = urllib.parse.urlencode({"eyebrow": eyebrow, "title": title, "sub": sub})
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
                        f"--user-data-dir={tmp}/profile", "--window-size=1200,630", f"--screenshot={png}",
                        (ROOT / "scripts" / "og-image.html").as_uri() + "?" + query],
                       check=True, capture_output=True, timeout=60)
        jpg = out / f"{slug}.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "82", str(png), "--out", str(jpg)],
                       check=True, capture_output=True)
        image = f"{BASE}social/{slug}.jpg"
        alt = f"{eyebrow}: {title}. {sub} Latchkey, latchkey.snackstud.io."
        text = re.sub(r'(<meta property="og:image" content=")[^"]*', lambda m: m.group(1) + image, text, count=1)
        text = re.sub(r'(<meta name="twitter:image" content=")[^"]*', lambda m: m.group(1) + image, text, count=1)
        text = re.sub(r'<meta property="og:image:type" content="[^"]*"', '<meta property="og:image:type" content="image/jpeg"', text, count=1)
        for key in ("og:image:alt", "twitter:image:alt"):
            attr = "property" if key.startswith("og") else "name"
            text = re.sub(rf'(<meta {attr}="{key}" content=")[^"]*', lambda m: m.group(1) + html.escape(alt), text, count=1)

        def fix(m):
            graph = json.loads(m.group(2))
            for node in graph.get("@graph", []):
                if node.get("@type") == "WebPage" and "primaryImageOfPage" in node:
                    node["primaryImageOfPage"].update({"url": image, "caption": alt})
            return m.group(1) + "\n" + json.dumps(graph, indent=2, ensure_ascii=False) + "\n  " + m.group(3)
        text = re.sub(r'(<script type="application/ld\+json">)(.*?)(</script>)', fix, text, flags=re.S)
        page.write_text(text)
        print(f"{slug}: {title}")
