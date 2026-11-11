# The website

The product site is static HTML in [`site/`](../site). There is no build step: what's in the folder is what is
served. It isn't hosted or connected to any service yet.

| File | What it is |
|---|---|
| `index.html` | The home page, led by "Your projects move. Your secrets don't.": a hero scene of a reference reaching a command, then four numbered movements (importing an env file, bringing the environment to a fresh clone, a second Mac, an agent asking), each beside a scene; the interactive approval panel; the app window; rotation; the key proxy; integrations; security in brief; Latchkey Pro's planned pricing; three ways in; and the closing band with install. Its CSS is inline |
| `features.html` | Capabilities in six groups (credentials, environments, devices, agents and tools, integrations, visibility), each with one example, an availability label and a link to its docs. Credentials opens with the working app window (`app-demo.js`); the other groups with scenes |
| `roadmap.html` | What's built, what's next and what's out of scope, by tier. The items are written in the HTML (the script only filters them); mark one **Built** only when the docs describe it as shipped |
| `pricing.html` | Plans modelled on Peel's: what stays free (storage, references, import, run, approvals, export), Latchkey Pro as a planned one-time license ($59 early, $79) with a year of updates, optional Pro Updates ($39 a year), Latchkey Teams ($15 per user a month, planned), a comparison marking planned rows, the update policy and short answers. Nothing is on sale; request buttons are disabled until a contact address is published |
| `teams.html` | Developer Credential Migration from Snack Studio (from $2,500, fixed scope) beside the inventory scene: deliverables, steps, credential handling beside the import scene, and limits; Latchkey Teams, looking for design partners |
| `security.html` | What each mechanism protects and doesn't, from `docs/security.md` and `SECURITY.md`: a scene of a script asking directly (the panel's warning), the six distinctions, each topic beside its heading, and the delivery-path and guarantees tables, which become one block per row on phones |
| `scenes.js` | The self-playing scenes: small drawings of Latchkey in use that play while on screen and start over. Each `.scene-wrap[data-scene]` names a script there; its HTML is the last frame in the landscape layout, which is what shows without scripts or with reduced motion. In a column narrower than 480px (a phone) each scene switches to its portrait layout in `PORTRAIT`, the same windows stacked in a canvas 360 wide so terminal text stays about 12px; motion is placed relative to the windows, so it works in both. Each has a pause button |
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

## Page rules

Every page keeps to these; they're what the layout passes checked, page by page, at 1440 and 375 pixels wide, in
light and dark:

- One header (Features, How it works, Pricing, Security, Docs, and **Install the preview**) and one footer on every
  page; product pages end with the closing call-to-action band (`.cta-band`).
- One type scale and rhythm from `site.css`: page titles 56px, section titles 36px, topic titles 28px, card titles
  17.5px; sections are `.section` (104px apart, 72px on phones). Cards are `.card` in a `.card-grid` (`g2`, `g3`,
  `g4`, chosen so rows balance); wide copy-beside-example panels are `.band`. Pages compose these and don't restyle
  them; drawings inside the app window and scenes use their own class names (`pane-card`, `icard`).
- No sideways scroll, and no visible scrollbars inside the page: code wraps between words, tables become one
  labelled block per row on phones, and the app window hides its pane scrollbars.
- A section opens with its heading and a wide example (a scene, the app window, a demo or a grid of cards) before
  longer text; text-only topics put their heading beside the text.
- Scenes float on the page's wash, use the app's own layouts, say they replay Latchkey's output with example data,
  and have captions at their width.
- "Read more" links are small and quiet (`.more`), and a card that goes somewhere is one link (`.card-link`, `.tool`),
  not an underlined title.
- On phones (checked at 320, 375 and 430 wide): controls are at least 40-44px tall, the pause button shows without
  hover, scenes run edge to edge with larger terminal type, and the header keeps Features, Pricing and Docs.
- Content reads without scripts, every image has alt text, each page has one `h1`, a title and a description, and
  loading or playing a page logs no errors.

## Keeping it true

The pages were audited against the Digital Presence Protocol (DPP 0.3.0, working draft): content is in the HTML
without scripts, scenes say they use example data, the product description matches across pages and `llms.txt`,
security claims that rest on Apple link to Apple's documentation, and JSON-LD only states what the page shows
(no offers or ratings). Keep those true when pages change.

Scenes and demos show only what Latchkey prints and shows. Terminal output in `scenes.js` and the home page's script
is copied from the `print` calls in `Sources/latchkey` (and panel wording from `App/Latchkey/ApprovalPanel.swift`);
when one changes, change the scene. Example data (project `shop`, values, dates, counts) is illustrative. A capability
that isn't verified for release carries a **Pending** label (`.avail.pending`) until it is.

The developer pages restate [cli.md](cli.md), [agents.md](agents.md) and the wire protocol in
`Sources/LatchkeyCore/Wire.swift`. Change them together: a new command, option, exit code, `op` or response field
belongs in both places. Every page shares the same header, sidebar and footer; change all of them at once.

## Before it goes live

- A contact address for early-access, migration and design-partner requests (and security reports): it enables
  the disabled request buttons on `pricing.html` and `teams.html`.
- Pro's purchase channel, refund and restore terms, published on `pricing.html` before it goes on sale; and a
  source license, so the source-available statement can name it.
- A domain, then canonical URLs, absolute `@id` and `url` values in the JSON-LD (relative until then), `og:url`, an Open Graph image (the pages use a text-only `summary` card until then)
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
