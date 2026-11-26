# The Pistachio website

Pistachio is the approved new name for Pistachio. The website source uses the owner-reviewed product-led
mockup and the supplied three-piece vector mark from `media/mark/SVG/pistachio-logo-colo.svg`. The current download
and all technical names (`Latchkey.app`, `pistachio`, `pst`, `pistachio://`, signing identifiers and support paths) remain
unchanged. The brand-transition note explains this; the app and domain migrations are separate owner decisions.

The product site is static HTML in [`site/`](../site). There is no build step: what's in the folder is what is
served. It's published at https://latchkey.snackstud.io from a Vercel project that never builds on push: deploys are manual (see Publishing below).

| File | What it is |
|---|---|
| `index.html` | The home page, led by "Your secrets. In a shell.": the open-shell photograph beside an interactive approval request (Deny prints the tool's refusal, Allow once runs the tests; both add an Activity line and offer Try again), then the "References in files. Values in Keychain." band, four numbered movements (importing an env file, bringing the environment to a fresh clone, a second Mac, an agent asking), each beside a scene; the interactive approval panel; the app window; rotation; the key proxy; integrations; security in brief; Pistachio Pro's planned pricing; three ways in; and the closing band with install. Page-specific CSS is inline; `pistachio.css` supplies the shared brand treatment |
| `features.html` | Capabilities in six groups (credentials, environments, devices, agents and tools, integrations, visibility), each with one example, an availability label and a link to its docs. Credentials opens with the working app window (`app-demo.js`); the other groups with scenes |
| `roadmap.html` | What's built, what's next and what's out of scope, by tier. The items are written in the HTML (the script only filters them); mark one **Built** only when the docs describe it as shipped |
| `pricing.html` | Plans modelled on Peel's: what stays free (storage, references, import, run, approvals, export), Pistachio Pro as a planned one-time in-app purchase in the Mac App Store ($79, updates included, no subscription), Pistachio Teams ($15 per user a month, planned), a comparison marking planned rows, the purchase policy and short answers. Nothing is on sale; early-access requests go to latchkey@snackstud.io |
| `teams.html` | Developer Credential Migration from Snack Studio (from $2,500, fixed scope) beside the inventory scene: deliverables, steps, credential handling beside the import scene, and limits; Pistachio Teams, looking for design partners |
| `security.html` | What each mechanism protects and doesn't, from `docs/security.md` and `SECURITY.md`: a scene of a script asking directly (the panel's warning), the six distinctions, each topic beside its heading, and the delivery-path and guarantees tables, which become one block per row on phones |
| `scenes.js` | The self-playing scenes: small drawings of Pistachio in use that play while on screen and start over. Each `.scene-wrap[data-scene]` names a script there; its HTML is the last frame in the landscape layout, which is what shows without scripts or with reduced motion. In a column narrower than 480px (a phone) each scene switches to its portrait layout in `PORTRAIT`, the same windows stacked in a canvas 360 wide so terminal text stays about 12px; motion is placed relative to the windows, so it works in both. Each has a pause button |
| `pistachio.css` | The owner-reviewed visual identity: clean system sans-serif, warm white, restrained green, product-led hero, responsive layouts and explicit light/dark tokens. Loaded after the base and page styles on every page. |
| `site.css` | Base shared styles: the icon set (`.ic .ic-NAME`, masks drawn in the text colour, after the SF Symbols the app uses; card symbols are `.cico`), colour tokens (light and dark) and section hues (`data-hue` on a section: blue, violet, teal, green, amber, rose, orange for Pro), header, footer, code blocks, the developer docs layout, feature rows, availability labels and the scenes |
| `app-demo.js` | An interactive Pistachio window on the home page and Features, laid out as the app is, with example data: the sidebar (All Items, Review, Activity, projects, services, Grants, Recently Deleted, the iCloud Keychain badge), a flat list of two-line rows with search and Type and Environment filters, and the item's detail as cards (value, reference, type, access, service, project, environment, note, location, history, recent activity). Row icons and colours follow the app's `ItemType` in `App/Latchkey/Style.swift`; keep them in step. It listens for the approval scene's `lk:activity` and `lk:grant` events, and sends `lk:revoke` when a grant is revoked there. Showing or copying a value and changing access go through a Touch ID sheet, as in the app |
| `site.js` | Copy buttons, and every code block coloured by part with an explanation of each on hover or focus: `pst` commands (action, option, value, the program it runs) and their synopses' placeholders, the other programs beside them (`SHELL`), env files and references, JSON fields (`JSONKEYS`), the agent note and the architecture diagram. Only the scenes and the home page's live demos are left alone. The same script adds the local appearance control and closes the mobile disclosure menu after navigation. The explanations live in its `ACTIONS`, `FLAGS` and `ACTION_FLAGS`; keep them in step with the CLI and the API. On the home page each code block is one keyboard stop and the arrow keys move between parts; on the developer pages explanations are hover-only, since the tables there cover every option |
| `changelog.html` | Every released version's notes, newest first, each under `id="vVERSION"`, written from `CHANGELOG.md` by `scripts/changelog-page.py` in the terms page's layout. The same script points every page's Changelog link here and sets the home page's "Latest version" (`<a data-latest-version>`). The update feed links each version's entry here |
| `privacy.html`, `terms.html`, `support.html` | The privacy policy, terms of use (the App Store EULA for store copies, FSL for the source) and support, linked from every footer. Keep the privacy policy in step with every network request the app or tool makes |
| `404.html` | The page for a missing path: `noindex`, root-absolute links, what `pst get` prints for a missing name (copied from `failMissing` in `Sources/latchkey/main.swift`), and cards to Features, Pricing, Security and reporting a broken link |
| `og.png`, `social/` | Social cards, 1200×630, rendered by `scripts/social-images.py` using standard-library Python and native macOS AppKit: `og.png` for the home page, scaled from the supplied artwork in `scripts/og-home.webp`, and a drawn card per page in `social/`. `scripts/og-image.html` previews the drawn card |
| `cli.html` | Getting the command-line tool: Homebrew or the signed download for the Mac App Store version, or from inside the direct download |
| `guides/` | Seventeen task-sized guides in four categories (env files, coding agents, deploying, everyday use) and their index, in the developer docs' layout: the shared sidebar (which links to the categories), breadcrumbs, "On this page", an "In short" answer and a "What this doesn't do" section. Each is a `TechArticle` with a byline; commands and limits come from `docs/`, as on every page. Links start with `../` |
| `humans.txt` | Who makes Pistachio and how the site is built |
| `favicon.ico`, `favicon-32.png`, `icon-*.png`, `site.webmanifest` | Browser and home-screen icons rendered by `scripts/social-images.py` from the supplied website mark; native app icons are not changed |
| `llms-full.txt` | The text of every page's main content, written by `scripts/discovery.py` |
| `<key>.txt` | The IndexNow key, so search engines that take IndexNow accept URLs submitted for this host |
| `logo.svg` | The supplied three-piece Pistachio vector mark, used in the header, the illustrated interfaces and generated web assets. Geometry and colors are retained from the owner’s asset |
| `apple-touch-icon.png` | 180×180, rendered from `logo.svg` by `scripts/social-images.py` |
| `developers/` | Developer docs: overview, quickstart, CLI reference, agents and MCP, references and API. The Quickstart plays the import and run scenes, Agents and MCP the agent scene. Code wraps instead of scrolling, and tables become one labelled block per row on phones (each `td` carries `data-th`) |
| `llms.txt` | Everything an agent needs in one file: the facts, the rules to follow, whether Pistachio is installed and how to get it, running commands, exit codes, approvals and grants, new clones, the proxy and AWS, MCP, keeping values out of files, the limits, and absolute links to every page and guide. Keep it in step with `docs/agents.md` and `docs/cli.md`. Every page's header links here as **For agents**, and every footer as **For agents (llms.txt)** |
| `robots.txt` | Crawl policy |

The footer’s Appearance button cycles System, Light and Dark, saves `pistachio-theme` in this browser only, and restores it before paint. The privacy page states this local storage use.

The home page's interactive approval panel ("Try it") follows the real sequence: the panel as the app draws it
(allow once, or Allow from this folder for a time, until the agent quits or only for this command), with Touch ID
read in the panel (click the fingerprint to touch the sensor; **Use Password…** does the same), then the result, recorded in the menu bar panel above the
terminal and in the app window further down. As the command is typed, a completion list appears under it, drawn
from the same explanations. The visitor plays the person at the Mac: Deny prints the real refusal, Allow Once runs
the tests with the value concealed, and a grant shows the next run going through or, limited to one command, asking
again. The proxy scene lets the visitor call the API, print, encode or send the key, and see only the placeholder
leave. With reduced motion they jump between steps; without scripts, static figures stand in.

Links are relative and end in `.html`, so the folder works from any host or opened from disk. Fonts are the
system's, so pages make no third-party requests.

## Page rules

Apply these rules to every page. Verify representative product, developer and guide pages at wide and narrow
widths in light and dark; a static link/metadata audit covers all pages:

- One header (Features, How it works, Pricing, Security, Developers, Guides, and **Download for Mac**) and one footer on every
  page. The footer has the mark, a line on what Pistachio does and the download, then Product, Developers and Trust and
  help columns, and a base line with the publisher and license; generate it for every page at once, since docs pages
  link with `../` and the 404 with `/`. Product pages end with the closing call-to-action band (`.cta-band`): **Download free** first, **See what Pro adds** second. Free leads every primary button; Pro is shown as planned until it is on sale.
- On phones: every link or button outside running text is at least 32px tall (most 44), inline code breaks at
  spaces and never inside a hyphenated word (`site.js`), and wide tables stack one row per block.
- The developer docs and the guides share one sidebar, consistent across those pages (Developers and Guides, with icons),
  so moving between them changes only the article; its Guides group links to the four categories, so it stays short as guides are added. It sticks right under the header, and space for the scrollbar is
  always reserved (`scrollbar-gutter: stable`), so pages don't shift sideways. Browsers with cross-document view
  transitions keep the header and sidebar still and fade only the content. On phones the sidebar shows the current
  group's links as a row. Change the sidebar on every page at once.
- Audited end to end on 2026-11-14: Lighthouse (mobile and desktop) on every page, axe-core for WCAG 2.0 A and AA in
  light and dark at phone and desktop widths, a crawl of every link, and a reader's review. Scenes reserve their
  portrait size on phones and stay invisible until laid out, so the page doesn't shift (`--pw`/`--ph` on the
  scene, `html.js` from the inline script in the head). Their pause button stays reachable; only the drawing is
  hidden from assistive technology. Drawings use styled text, not headings, so the outline stays in order.
- No single word on a line of its own: text wraps `pretty`, and `site.js` holds each paragraph's, item's, cell's and
  heading's last two words together where they fit. Cards in a row end level: a card's example and link sit at its foot,
  its availability label sits beside its symbol, and plan notes sit above their buttons so the buttons line up. A card
  much lighter than its neighbours gets a real example or detail, never filler.
- One type scale and rhythm from `site.css`: page titles 56px, section titles 36px, topic titles 28px, card titles
  17.5px; sections are `.section` (104px apart, 72px on phones). Cards are `.card` in a `.card-grid` (`g2`, `g3`,
  `g4`, chosen so rows balance); wide copy-beside-example panels are `.band`. Pages compose these and don't restyle
  them; drawings inside the app window and scenes use their own class names (`pane-card`, `icard`).
- No sideways scroll, and no visible scrollbars inside the page: code wraps between words, tables become one
  labelled block per row on phones, and the app window hides its pane scrollbars.
- A section opens with its heading and a wide example (a scene, the app window, a demo or a grid of cards) before
  longer text; text-only topics put their heading beside the text.
- Scenes float on the page's wash, use the app's own layouts, say they replay Pistachio's output with example data,
  and have captions at their width.
- "Read more" links are small and quiet (`.more`), and a card that goes somewhere is one link (`.card-link`, `.tool`),
  not an underlined title.
- On phones (checked at 320, 375 and 430 wide): controls are at least 40-44px tall, the pause button shows without
  hover, scenes run edge to edge with larger terminal type, and the header stays one row: below 1000px it drops How it works and Security, below 720px the download button, and below 480px Features, leaving Pricing, Developers and Guides.
- Content reads without scripts, every image has alt text, each page has one `h1`, a title and a description, and
  loading or playing a page logs no errors.

## Keeping it true

The pages were audited against the Digital Presence Protocol (DPP 0.3.0, working draft): content is in the HTML
without scripts, scenes say they use example data, the product description matches across pages and `llms.txt`,
security claims that rest on Apple link to Apple's documentation, and JSON-LD only states what the page shows
(no ratings, and the only offer is the free download). Keep those true when pages change. [presence.md](presence.md)
holds the records the protocol asks for: the entities, every public claim with its evidence and the surfaces that
carry it, the surface list with correction routes, the access checks, and the metrics and query panel, none of which
has data yet. A claim that changes is corrected everywhere that table lists it, and noted in `CHANGELOG.md`.

Every page has a descriptive title, a description under about 170 characters that its Open Graph and X cards repeat,
a canonical link, its own social card with alt text, `robots` allowing large image previews, the icons and manifest,
and `rel="author"` and `meta name="author"` for Zach Shallbetter. Each page's JSON-LD is one graph: the `WebPage`
(author Zach Shallbetter, publisher Snack Studio, its card as the primary image), its breadcrumbs, the `Person`
(`https://zachshallbetter.com/#person`) and the `Organization` (`https://www.snackstud.io/#organization`). Those two
IDs are the ones Snack Studio's other sites use, so search engines can tell it's the same person and studio; the home
page adds the website and the app, whose author and creator is the person. The visible credit is the footer byline
on every page, the "Who makes Pistachio" section on the home page, the guides' bylines and `humans.txt`; it's worded
for Pistachio, not copied from the other sites. Support has the route for reporting a mistake on the site.

Scenes and demos show only what Pistachio prints and shows. Terminal output in `scenes.js` and the home page's script
is copied from the `print` calls in `Sources/latchkey` (and panel wording from `App/Latchkey/ApprovalPanel.swift`);
when one changes, change the scene. Example data (project `shop`, values, dates, counts) is illustrative. A capability
that isn't verified for release carries a **Pending** label (`.avail.pending`) until it is.

The developer pages restate [cli.md](cli.md), [agents.md](agents.md) and the wire protocol in
`Sources/LatchkeyCore/Wire.swift`. Change them together: a new command, option, exit code, `op` or response field
belongs in both places. Every page shares the same header, sidebar and footer; change all of them at once.

## Before it goes live

- The page says Apple silicon and Intel: try the release on an Intel Mac.
- The pages say keys and environment records sync to every Mac: try clone, export and run on a second Mac, then
  remove the **Second-Mac test pending** labels from `index.html`, `features.html` and `security.html`.

## Publishing

The site is a Vercel project with its root directory set to the repository root; `vercel.json` serves `site/` as is,
with no build, and turns off Git deployments, so pushes and merges never deploy. Publish from a clean checkout of
`main`, on request:

```bash
vercel deploy --prod
```

Before publishing, regenerate the changelog page if `CHANGELOG.md` changed (`python3 scripts/changelog-page.py`), the
social cards if a page's title or description changed, then the discovery files, so each page's date is its last
change and `llms-full.txt` matches the pages:

```bash
python3 scripts/social-images.py
```

```bash
python3 scripts/discovery.py
```

Canonical URLs, `og:url`, the JSON-LD `@id` and `sitemap.xml` use https://latchkey.snackstud.io/; a new page
needs its canonical link (the scripts pick it up). After a publish, the owner may tell IndexNow about changed pages
(Bing, Yandex and others; not Google), with the key in `site/`:

```bash
curl "https://api.indexnow.org/indexnow?url=https://latchkey.snackstud.io/&key=cd052edf0f35d73aff8be1e0017f88e0"
```

Search Console and Bing Webmaster Tools need the owner's verification; neither is set up. After a publish, fetch each sitemap URL and record the
result in [presence.md](presence.md); that's the first production observation. `404.html` is served for missing
paths at any depth, so unlike every other page its links start at `/`.

## Previewing

Run from the website worktree through the register, using the active session ID:

```bash
REG_SESSION_ID=<session-id> ~/Projects/_worktrees/.register/reg serve pistachio-site --port 58296 -- python3 -m http.server '{port}' --bind 127.0.0.1 --directory site
```

Open `http://127.0.0.1:58296/`. Register ownership must be joined before serving. Run asset generation and local
checks through `reg build --label <check-name> -- <command>` as well.

## Pistachio presentation

The website follows the owner's style guide (November 2026): Canvas `#191C19`, Surface `#252825`, Raised `#343834`,
Rule `#474D47`, Ink `#F6F7F2`, Muted `#C1C7BD` and Pistachio `#C6EF61` with `#17200D` labels, in `pistachio.css`. That
palette is the default appearance; the footer's Appearance control still offers the earlier light palette. Pistachio
green marks actions, selection and emphasised phrases; blue, amber and rose stay with item and Touch ID glyphs. Focus
is a 2px Pistachio outline offset 3px.

The header is the same on every page: How it works, Pricing, Security, Developers and **For agents** (`llms.txt`).
Features and Guides are in every footer. Small screens use a native disclosure menu with the same links.

The home hero starts with a decision: five columns of copy and the one Download for Mac button (Try the demo beside
it moves focus to the example, compatibility beneath), seven of art. The open-shell photograph (`hero-pistachio.webp`,
from the app's welcome artwork) sits in a local olive wash beside the approval request, labelled "Interactive demo ·
Example credentials", which uses the generic requester "Agent". Below 1280px copy and demo stay side by side and the nut
shrinks behind the demo; below 760px the hero stacks and the nut is left out, so the demo (at most 520px wide) keeps
two legible key names and both actions. Appearance choices restore
before page styling on every page. No new command, wire protocol, trust identity, domain or payment product is
introduced.

Regenerate social cards and icons through the register on macOS, then discovery and context. Check all local links,
page titles/metadata, JavaScript syntax, and representative desktop/mobile and light/dark browser flows. A new
public domain, app rename and production deployment remain separate owner-directed work.

The brand line is “Your secrets. In a shell.”: a reference to the Pistachio name and terminal workflows.
The owner-selected future domain is `secretsinashell.com`; canonical URLs and the production host remain
unchanged until a separate domain migration.

App depictions (the working app demo and the approval scenes) use an independent neutral palette with blue
controls and selections, and don't inherit the site's green. This changes web depictions only.

Container depth uses three shared shadow levels for inset code/callouts, cards, and floating app windows,
with theme-specific shadows. Flat audience rows and nested app fields inherit their parent’s depth.
Homepage containers gently lift/fade during scroll entry using feature-detected native view timelines;
unsupported browsers and reduced-motion users receive static, fully visible content. Keyboard focus
settles the animated container immediately; clickable cards also lift slightly on precise-pointer hover.

Public documentation uses Pistachio, `pst`, current reference examples and current MCP names. Rename/migration
notes are omitted from product pages. Real repository, package, source and signing identifiers remain accurate.
