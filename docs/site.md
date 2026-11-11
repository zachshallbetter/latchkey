# The website

The product site is static HTML in [`site/`](../site). There is no build step: what's in the folder is what is
served. It isn't hosted or connected to any service yet.

| File | What it is |
|---|---|
| `index.html` | The home page. Its own CSS is inline; the terminal and approval panel in the hero are HTML, not images |
| `site.css` | Shared styles: colour tokens (light and dark), header, footer, code blocks, and the developer docs layout |
| `site.js` | Copy buttons on code blocks |
| `logo.svg` | The mark, used in the header, hero, favicon and download box. Replace this one file to change the logo |
| `developers/` | Developer docs: overview, quickstart, CLI reference, agents and MCP, references and API |
| `llms.txt` | Plain-text facts, agent instructions and links for language-model tools |
| `robots.txt` | Crawl policy |

Links are relative and end in `.html`, so the folder works from any host or opened from disk. Fonts are the
system's, so pages make no third-party requests.

## Keeping it true

The developer pages restate [cli.md](cli.md), [agents.md](agents.md) and the wire protocol in
`Sources/LatchkeyCore/Wire.swift`. Change them together: a new command, option, exit code, `op` or response field
belongs in both places. Every page shares the same header, sidebar and footer; change all of them at once.

## Before it goes live

- A domain, then canonical URLs, `og:url`, an Open Graph image and a sitemap.
- The **Download** buttons point at this repository's latest GitHub release, which only works once releases are
  public.
- Hosting, with deploys run on request rather than on every push.

## Previewing

```bash
cd site && python3 -m http.server 8000
```
