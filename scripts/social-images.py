#!/usr/bin/env python3
"""Render Pistachio social cards and web icons with macOS AppKit, without a browser or external packages.

Run from a Mac before publication, through reg build. Published URLs intentionally remain on the existing host
until the owner registers and authorizes a domain migration. The site uses the owner-supplied Pistachio vector mark; native app assets are managed separately.
"""
import html
import json
import pathlib
import re
import struct
import subprocess
import tempfile
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
BASE = "https://latchkey.snackstud.io/"


def card_text(page, text):
    title = html.unescape(re.search(r"<title>(.*?)</title>", text, re.S).group(1)).split(" · ")[0]
    description = html.unescape(re.search(r'<meta name="description" content="([^"]*)"', text).group(1))
    return title, description


def svg_card(title, description):
    title_lines = textwrap.wrap(title, width=35, break_long_words=False, break_on_hyphens=False)[:3]
    description_lines = textwrap.wrap(description, width=73, break_long_words=False, break_on_hyphens=False)[:2]
    title_y = 235 if len(title_lines) < 3 else 210
    lines = ''.join(f'<text x="76" y="{title_y + index * 70}" font-size="59" font-weight="700">{html.escape(line)}</text>' for index, line in enumerate(title_lines))
    bottom = title_y + len(title_lines) * 70 + 12
    lines += ''.join(f'<text x="76" y="{bottom + index * 39}" font-size="27" fill="#5D655F">{html.escape(line)}</text>' for index, line in enumerate(description_lines))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
<rect width="1200" height="630" fill="#FAFAF6"/>
<g transform="translate(72 49) scale(.62)">{MARK}</g>
<g font-family="Helvetica,Arial,sans-serif" fill="#181E1A"><text x="148" y="94" font-size="39" font-weight="700">Pistachio</text>
<text x="1124" y="88" text-anchor="end" font-size="21" fill="#315842">A MAC APP BY SNACK STUDIO</text>
<path d="M76 132H1124" stroke="#DFE4DB"/>{lines}
<rect x="76" y="530" width="242" height="48" rx="8" fill="#315842"/>
<text x="197" y="561" text-anchor="middle" font-size="23" font-weight="600" fill="#FFFFFF">Free for your Mac</text>
<text x="1124" y="563" text-anchor="end" font-size="22" fill="#5D655F">Your secrets. In a shell.</text></g></svg>'''


logo_source = (SITE / 'logo.svg').read_text()
logo_viewbox = re.search(r'viewBox="([^"]+)"', logo_source)
if not logo_viewbox:
    raise SystemExit('The website mark must declare a viewBox.')
_, _, logo_width, logo_height = map(float, logo_viewbox[1].split())
logo_scale = min(96 / logo_width, 96 / logo_height)
logo_inner = re.sub(r'^.*?<svg[^>]*>|</svg>\s*$', '', logo_source, flags=re.S)
MARK = f'<g transform="translate({(96-logo_width*logo_scale)/2} {(96-logo_height*logo_scale)/2}) scale({logo_scale})">{logo_inner}</g>'
SWIFT = r'''
import AppKit
import Foundation
struct Job: Decodable { let input: String; let output: String; let width: Int; let height: Int; let jpeg: Bool }
enum RenderError: Error { case invalidImage(String), allocationFailed, encodingFailed }
let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for job in jobs {
    guard let image = NSImage(contentsOfFile: job.input) else { throw RenderError.invalidImage(job.input) }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: job.width, pixelsHigh: job.height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { throw RenderError.allocationFailed }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: job.width, height: job.height))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: job.jpeg ? .jpeg : .png,
        properties: job.jpeg ? [.compressionFactor: 0.88] : [:]) else { throw RenderError.encodingFailed }
    try data.write(to: URL(fileURLWithPath: job.output))
}
'''


def main():
    out = SITE / 'social'
    out.mkdir(exist_ok=True)
    jobs = []
    pages = sorted(p for p in SITE.rglob('*.html') if p.name != '404.html')
    with tempfile.TemporaryDirectory(prefix='pistachio-artwork-') as temporary:
        temporary = pathlib.Path(temporary)
        for index, page in enumerate(pages):
            text = page.read_text()
            title, description = card_text(page, text)
            home = page == SITE / 'index.html'
            if home:
                title, description = 'Your secrets. In a shell.', 'API keys and credentials, kept in Keychain. Ready for the commands and coding agents you approve.'
            slug = page.relative_to(SITE).as_posix().replace('/', '-').removesuffix('.html')
            svg = temporary / f'{index}.svg'
            svg.write_text(svg_card(title, description))
            destination = SITE / 'og.png' if home else out / f'{slug}.jpg'
            # The home card is the supplied artwork (1731 × 908, the same shape as 1200 × 630); other pages get a drawn card.
            source = pathlib.Path(__file__).with_name('og-home.webp') if home else svg
            jobs.append(dict(input=str(source), output=str(destination), width=1200, height=630, jpeg=not home))
            image_url = BASE + destination.relative_to(SITE).as_posix()
            alt = f'{title.rstrip(".")}. Pistachio, a Mac app from Snack Studio.'
            for key in ('og:image', 'twitter:image'):
                text = re.sub(r'(<meta (?:property|name)="'+re.escape(key)+r'" content=")[^"]*', lambda m: m[1] + image_url, text, count=1)
            for key in ('og:image:alt', 'twitter:image:alt'):
                text = re.sub(r'(<meta (?:property|name)="'+re.escape(key)+r'" content=")[^"]*', lambda m: m[1] + html.escape(alt), text, count=1)
            text = re.sub(r'(<meta property="og:image:type" content=")[^"]*', lambda m: m[1] + ('image/png' if home else 'image/jpeg'), text, count=1)
            def graph(match):
                data = json.loads(match[2])
                for node in data.get('@graph', []):
                    if node.get('@type') == 'WebPage' and 'primaryImageOfPage' in node:
                        node['primaryImageOfPage'].update(url=image_url, caption=alt)
                return match[1] + '\n' + json.dumps(data, indent=2, ensure_ascii=False) + '\n  ' + match[3]
            text = re.sub(r'(<script type="application/ld\+json">)(.*?)(</script>)', graph, text, flags=re.S)
            page.write_text(text)
        for name, size in [('favicon-32.png', 32), ('apple-touch-icon.png', 180), ('icon-192.png', 192), ('icon-512.png', 512), ('icon-maskable-512.png', 512), ('favicon-48.png', 48)]:
            icon = temporary / (name + '.svg')
            icon.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><rect width="512" height="512" fill="#FAFAF6"/><g transform="translate(102 102) scale(3.2)">{MARK}</g></svg>')
            jobs.append(dict(input=str(icon), output=str(SITE / name) if name != 'favicon-48.png' else str(temporary / name), width=size, height=size, jpeg=False))
        (temporary / 'jobs.json').write_text(json.dumps(jobs))
        (temporary / 'render.swift').write_text(SWIFT)
        subprocess.run(['swift', str(temporary / 'render.swift'), str(temporary / 'jobs.json')], check=True, timeout=120)
        png = (temporary / 'favicon-48.png').read_bytes()
        # ICO permits a PNG-encoded image entry; no image library or proprietary icon format is needed.
        (SITE / 'favicon.ico').write_bytes(struct.pack('<HHH', 0, 1, 1) + struct.pack('<BBBBHHII', 48, 48, 0, 0, 1, 32, len(png), 22) + png)
    print(f'Rendered {len(pages)} social cards and 6 web icons using native AppKit.')


if __name__ == '__main__':
    main()
