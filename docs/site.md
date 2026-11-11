# The website

The product site is static HTML in [`site/`](../site). There is no build step: what's in the folder is what is
served. It isn't hosted or connected to any service yet.

| File | What it is |
|---|---|
| `index.html` | The home page: one column that follows the `shop` example from env file to rotation. Its CSS is inline; the terminal and approval panel are HTML drawn after the app's real panel, not images |
| `site.css` | Shared styles: colour tokens (light and dark), header, footer, code blocks, and the developer docs layout |
| `site.js` | Copy buttons on code blocks |
| `logo.svg` | The mark, used in the header, the drawn approval panel and the favicon. Replace this one file to change the logo |
| `apple-touch-icon.png` | 180×180, rendered from the app icon (`sips -s format png -z 180 180 …/AppIcon.icns`) |
| `developers/` | Developer docs: overview, quickstart, CLI reference, agents and MCP, references and API |
| `llms.txt` | Plain-text facts, agent instructions and links for language-model tools |
| `robots.txt` | Crawl policy |

The home page has three scenes, each redrawing only what Latchkey really prints and shows. In the approval
panel, the visitor plays the person at the Mac: Deny prints the real refusal, Allow Once runs the tests with the
value concealed, and a grant shows the next run going through or, limited to one command, asking again. The env
file rewrites itself into references. The proxy scene lets the visitor call the API, print, encode or send the key,
and see only the placeholder leave. With reduced motion they jump between steps; without scripts, static figures
stand in.

Links are relative and end in `.html`, so the folder works from any host or opened from disk. Fonts are the
system's, so pages make no third-party requests.

## Keeping it true

The developer pages restate [cli.md](cli.md), [agents.md](agents.md) and the wire protocol in
`Sources/LatchkeyCore/Wire.swift`. Change them together: a new command, option, exit code, `op` or response field
belongs in both places. Every page shares the same header, sidebar and footer; change all of them at once.

## Before it goes live

- A domain, then canonical URLs, `og:url`, an Open Graph image (the pages use a text-only `summary` card until then)
  and a sitemap.
- The download link and Homebrew command in **Install** on the home page (marked PLACEHOLDER).
- The **Download** buttons point at this repository's latest GitHub release, which only works once releases are
  public, and the page says the app is signed and notarized: notarize the release first (`scripts/release.sh`).
- The page says Apple silicon and Intel: try the release on an Intel Mac.
- The page says keys sync to every Mac: try it on a second Mac.
- Hosting, with deploys run on request rather than on every push.

## Previewing

```bash
cd site && python3 -m http.server 8000
```
