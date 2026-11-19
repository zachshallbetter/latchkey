"""CHANGELOG.md read into releases, and one release as HTML, for the update feed (update-appcast.py) and the site's
changelog page (changelog-page.py). The app reads the same file with LatchkeyCore's ReleaseNotes; both take the shape
`## VERSION (DATE)` / `### Section` / `- item` with indented continuation lines, and skip everything else."""
import html
import re


def parse(markdown):
    """[{"version", "date", "sections": [{"title", "items": [markdown, ...]}]}], newest first."""
    releases, item = [], None

    def end_item():
        nonlocal item
        if item is not None and releases and releases[-1]["sections"]:
            releases[-1]["sections"][-1]["items"].append(item)
        item = None

    for line in markdown.split("\n"):
        if line.startswith("## "):
            end_item()
            heading = line[3:].strip()
            m = re.fullmatch(r"(.+?)\s*\((.+)\)", heading)
            releases.append({"version": m.group(1) if m else heading, "date": m.group(2) if m else None, "sections": []})
        elif line.startswith("### "):
            end_item()
            if releases:
                releases[-1]["sections"].append({"title": line[4:].strip(), "items": []})
        elif line.startswith("- "):
            end_item()
            item = line[2:].strip()
        elif line.startswith("  ") and item is not None:
            item += " " + line.strip()
        else:
            end_item()
    end_item()
    return releases


def release(markdown, version):
    return next((r for r in parse(markdown) if r["version"] == version), None)


def inline_html(text):
    """Escaped, with `code`, **bold** and [links](url) as CHANGELOG.md writes them. Links keep only http(s) targets."""
    out, pos = [], 0
    for m in re.finditer(r"`([^`]+)`|\*\*(.+?)\*\*|\[([^\]]+)\]\((https?://[^)\s]+)\)", text):
        out.append(html.escape(text[pos:m.start()]))
        if m.group(1) is not None:
            out.append(f"<code>{html.escape(m.group(1))}</code>")
        elif m.group(2) is not None:
            out.append(f"<b>{html.escape(m.group(2))}</b>")
        else:
            out.append(f'<a href="{html.escape(m.group(4), quote=True)}">{html.escape(m.group(3))}</a>')
        pos = m.end()
    out.append(html.escape(text[pos:]))
    return "".join(out)


def release_html(rel, heading_level=3):
    """One release's sections as headings and lists."""
    parts = []
    for section in rel["sections"]:
        parts.append(f"<h{heading_level}>{html.escape(section['title'])}</h{heading_level}>")
        parts.append("<ul>" + "".join(f"<li>{inline_html(i)}</li>" for i in section["items"]) + "</ul>")
    return "\n".join(parts)
