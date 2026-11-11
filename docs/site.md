# The website

The product site is static HTML in [`site/`](../site). There is no build step: what's in the folder is what is
served. It isn't hosted or connected to any service yet.

| File | What it is |
|---|---|
| `index.html` | The home page: a hero scene of a reference reaching a command, then four numbered movements (a fresh clone, importing an env file, a second Mac, an agent asking), each beside a scene; the interactive approval panel; the app window; rotation; the key proxy; integrations; security in brief; install. Its CSS is inline |
| `features.html` | Capabilities in six groups (credentials, environments, devices, agents and tools, integrations, visibility), each with one example, an availability label and a link to its docs. Credentials opens with the working app window (`app-demo.js`); the other groups with scenes |
| `roadmap.html` | What's built, what's next and what's out of scope, by tier. The items are the `tiers` list in its script; mark one `built: true` only when the docs describe it as shipped |
| `security.html` | What each mechanism protects and doesn't, from `docs/security.md` and `SECURITY.md`: a scene of a script asking directly (the panel's warning), the six distinctions, each topic beside its heading, and the delivery-path and guarantees tables, which become one block per row on phones |
| `scenes.js` | The self-playing scenes: small drawings of Latchkey in use that play while on screen and start over. Each `.scene-wrap[data-scene]` names a script there; its HTML is the last frame, which is what shows without scripts or with reduced motion. Each has a pause button |
| `site.css` | Shared styles: colour tokens (light and dark), header, footer, code blocks, the developer docs layout, feature rows, availability labels and the scenes |
| `app-demo.js` | A working copy of the Latchkey window on the home page and Features, with example data: sidebar filters and counts, the project and environment tree, item detail, Activity and Grants. It listens for the approval scene's `lk:activity` and `lk:grant` events, and sends `lk:revoke` when a grant is revoked there. Showing a value or changing a setting goes through a Touch ID sheet, as in the app |
| `site.js` | Copy buttons, and `lk` commands coloured by part (action, option, value, the program it runs) with an explanation of each on hover or focus. The explanations live in its `ACTIONS` and `FLAGS`; keep them in step with the CLI. On the home page each code block is one keyboard stop and the arrow keys move between parts; on the developer pages explanations are hover-only, since the tables there cover every option |
| `logo.svg` | The mark, used in the header, the drawn approval panel and the favicon. Replace this one file to change the logo |
| `apple-touch-icon.png` | 180×180, rendered from the app icon (`sips -s format png -z 180 180 …/AppIcon.icns`) |
| `developers/` | Developer docs: overview, quickstart, CLI reference, agents and MCP, references and API. The Quickstart plays the import and run scenes, Agents and MCP the agent scene. Code wraps instead of scrolling, and tables become one labelled block per row on phones (each `td` carries `data-th`) |
| `llms.txt` | Plain-text facts, agent instructions and links for language-model tools |
| `robots.txt` | Crawl policy |

The home page's interactive approval panel ("Try it") follows the real sequence: the panel as the app draws it
(Allow Once, or Allow from this folder for a time, until the agent quits or only for this command), then the
system's Touch ID sheet with Latchkey's own wording, then the result, recorded in the menu bar panel above the
terminal and in the app window further down. As the command is typed, a completion list appears under it, drawn
from the same explanations. The visitor plays the person at the Mac: Deny prints the real refusal, Allow Once runs
the tests with the value concealed, and a grant shows the next run going through or, limited to one command, asking
again. The proxy scene lets the visitor call the API, print, encode or send the key, and see only the placeholder
leave. With reduced motion they jump between steps; without scripts, static figures stand in.

Links are relative and end in `.html`, so the folder works from any host or opened from disk. Fonts are the
system's, so pages make no third-party requests.

## Keeping it true

Scenes and demos show only what Latchkey prints and shows. Terminal output in `scenes.js` and the home page's script
is copied from the `print` calls in `Sources/latchkey` (and panel wording from `App/Latchkey/ApprovalPanel.swift`);
when one changes, change the scene. Example data (project `shop`, values, dates, counts) is illustrative. A capability
that isn't verified for release carries a **Pending** label (`.avail.pending`) until it is.

The developer pages restate [cli.md](cli.md), [agents.md](agents.md) and the wire protocol in
`Sources/LatchkeyCore/Wire.swift`. Change them together: a new command, option, exit code, `op` or response field
belongs in both places. Every page shares the same header, sidebar and footer; change all of them at once.

## Before it goes live

- A domain, then canonical URLs, `og:url`, an Open Graph image (the pages use a text-only `summary` card until then)
  and a sitemap.
- Publish a signed and notarized release first (`scripts/release.sh`), then replace the **Preview status**
  actions and source installation instructions with the public download and Homebrew command.
- The page says Apple silicon and Intel: try the release on an Intel Mac.
- The pages say keys and environment records sync to every Mac: try clone, export and run on a second Mac, then
  remove the **Second-Mac test pending** labels from `index.html`, `features.html` and `security.html`.
- Hosting, with deploys run on request rather than on every push.

## Previewing

```bash
cd site && python3 -m http.server 8000
```
