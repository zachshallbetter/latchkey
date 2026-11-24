# Pistachio for Chrome and Firefox

Status: local development builds. Neither extension has been published. Chrome and Firefox share Safari’s
Pistachio artwork, key detection, save/fill controls and popup. Every save and fill still requires the app’s approval.
The owner approved the [native connection design](browser-extension-connection.md) on November 23, 2026.

## Build

```bash
python3 scripts/build-browser-extensions.py
```

Outputs under `build/browser-extensions/`:

- `chrome/` and `pistachio-chrome.zip`: unpacked Chrome MV3 extension and reproducible archive.
- `firefox/` and `pistachio-firefox.xpi`: Firefox MV3 extension and unsigned development archive.
- `build-info.json`: archive SHA-256 hashes.

Chrome uses a service worker and requires Chrome 120 or later. Firefox uses background scripts and requires
Firefox 142 or later. Its data disclosures include authentication information, website activity and website
content because an approved save sends a detected credential and its page context to the local native app.
Detection itself runs locally; no remote collection service is added.

## Try a development build

First build and install the updated Pistachio app using `scripts/install.sh`, then open it. The app must contain
`Contents/Helpers/pistachio-browser-host`; an older branded app without this helper cannot connect. The retained
installation filename is `/Applications/Latchkey.app`.

1. In Chrome, open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select
   `build/browser-extensions/chrome`. Copy the actual extension ID shown by Chrome.
2. In Firefox, open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and select
   `build/browser-extensions/firefox/manifest.json`. This temporary add-on is removed when Firefox exits.
3. Preview setup, then register only the browsers being tested:

```bash
python3 scripts/setup-browser-connection.py --chrome-id YOUR_CHROME_EXTENSION_ID --firefox --dry-run
python3 scripts/setup-browser-connection.py --chrome-id YOUR_CHROME_EXTENSION_ID --firefox
```

Omit a browser’s option when it is not needed. `--app /absolute/path/to/Latchkey.app` selects another signed build.
Setup checks the app, helper signature and shared container, writes per-user native-host manifests, and records
only allowed extension IDs in `browser-host-allowlist.json` in the app’s existing shared container. Repeated Chrome
IDs can be supplied; a new Chrome setup replaces the configured Chrome ID list. No browser/site permissions are
granted by this script. Choose site access in the browser. Open the popup to check connectivity, then use a test
credential to exercise saving, refusal and filling with the app’s approval panel.

To remove registrations, run the same command with `--remove`; keep the signed app installed until removal is
complete. Removing the connection does not delete vault items. Setup is currently a developer script; there is no
Settings installer or store listing yet. Only Google Chrome and Mozilla Firefox are supported by the parent-process
checks; other Chromium browsers need separately reviewed support.

## Connection and limits

Both packages use native host `io.snackstud.pistachio`. The signed helper authenticates its browser parent and
configured extension arguments, then connects to `browser.sock` in the existing App Group container. The app admits
only helper identity `io.snackstud.pistachio.browser` from its signing team. Its gate allows `status`, `list`, `set`
and `fill`, and refuses CLI reads, exports, grants and execution. Safari retains its existing handler and endpoint.
The shared translator never offers a general broker passthrough.

Unit tests, deterministic package checks, Firefox manifest lint and a signed direct-app build cover the local
candidate. On November 23, 2026, the updated signed app was installed and both Chrome and Firefox displayed
“Connected to Pistachio” through their native messaging helpers. Chrome used its unpacked extension; Firefox used
a temporary unsigned add-on. This verifies status connectivity, not a complete live save/fill approval flow. The sandboxed
build targets the same App Group connection; compilation does not establish runtime parity or App Store approval.
User-selected registration-folder access and signed sandbox runtime verification remain release work.

Firefox rejects an unsigned XPI through ordinary installation with “This add-on could not be installed because it
has not been verified.” Use the temporary flow above for development; do not disable signature enforcement.
[Mozilla explains the signing requirement](https://support.mozilla.org/en-US/kb/add-on-signing-in-firefox).
Firefox permanent installation requires Mozilla signing. Chrome distribution requires the Chrome Web Store release
workflow. Store accounts, publication, privacy review and release signing remain owner actions.

References: [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging),
[Firefox background contexts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background),
[Mozilla data consent](https://www.extensionworkshop.com/documentation/develop/firefox-builtin-data-consent/).

## Save Selection after an extension update

Selecting **Save Selection to Pistachio** opens an in-page form beside the selected text, with the source host visible. Page title and detection rationale are available under **About this suggestion**.
Query strings are omitted, and any exact selected value in the title is masked. It does not save immediately. Chrome and Firefox
use the selection captured by the browser menu, rather than relying on the page to retain its highlight. If a tab
was already open when the extension was installed or reloaded, the command first tries the existing listener,
then restores the bundled content scripts in the main frame and retries once. Browser packages declare `scripting`
for that recovery, using the menu invocation’s existing `activeTab` access. No new native broker powers are added.

Restricted pages or missing site access produce a `!` toolbar badge, a recovery tooltip and guidance in the popup.
Reload the page, allow the extension on that site, select the text again and retry. Framed selections and selections
over the supported limit are refused. Test values verified opening the panel on an existing Chrome tab after
extension reload; completing a real vault save still requires the Mac app’s approval and was not part of that check.

## Context-aware detection

All browsers share the same local detector. Known credential formats remain strong evidence. Unfamiliar opaque
values can qualify from a credential’s own label or variable name, or from a bounded local group that combines
credential wording with creation/reveal cues. Randomness, an API-key page title or a provider hostname alone does
not qualify a value. Nearby means a small containing group, not the whole document body.

Provider suggestions use exact dashboard hosts or explicit provider variable/label names. For example, an unfamiliar
dotted token beside “API Key” on Google AI Studio can suggest `GEMINI_API_KEY`, preserving the complete value.
An explicit variable such as `PAYMENTS_API_KEY` is retained. Local live/test labels can suggest an environment;
ambiguous labels do not. Context-based results explain their evidence under **About this suggestion** in the save panel.
These are editable hints, not proof of issuer, validity or permission to fill a site.

Request/project/client IDs, checksums, CSRF/verification tokens, examples, masked values and public/publishable
labels suppress credential suggestions. Unlabeled hashes and UUIDs stay decoys. Public key/certificate envelopes
are identified as public items and never promoted to high-confidence secret offers. Documentation caps confidence.
The existing known AWS access-key-ID format remains supported when labeled, even though the ID alone is not a
secret. Password/hidden input exclusions remain in place.

Context is bounded: local groups up to 1,500 characters, titles up to 160, paths up to 200. Query strings and
fragments are excluded. Classification makes no provider requests and sends no new context fields to the app.
Saving still requires an explicit action and the app’s approval. After success, the form becomes a compact
confirmation with **Copy reference** and **Done**; command instructions remain under **Use in your project**. Detection is heuristic; manual selection remains
available for formats the detector misses.
