# Latchkey for Chrome (proposal)

Status: **proposed, not built.** Latchkey has a Safari extension only. This page describes how a Chrome extension
would work and what it would add to Latchkey's trust boundary, so the decision can be made before any code. It adds
a new caller identity and a new way into the broker, so it needs the owner's approval first.

## What it would do

The same thing as Latchkey for Safari ([app.md](app.md#latchkey-for-safari)): spot a new key on the page where it was
made and save it when you say so, and fill a saved key into a field on a site the app allows. Nothing new is allowed:
the same four broker operations (`status`, `list`, `set`, `fill`), the same approvals (every save and every fill asks),
and the same fill rules, decided by the app from the page's origin.

Chromium browsers share one extension and one native messaging design: Google Chrome (including Beta, Dev and Canary),
Microsoft Edge, Brave, Arc, Vivaldi and Chromium. "Chrome" below means all of them.

## How Safari's extension reaches the app today

```
content.js ─► background.js ─► Safari ─► SafariWebExtensionHandler (appex, sandboxed)
                                               │ JSON line over a Unix socket in the App Group container
                                               ▼
                                   Broker, gate .safariExtension (code signature io.snackstud.latchkey.safari;
                                   ops status, list, set, fill)
```

Safari runs the native handler for us, inside the app bundle, and the app admits it by code signature.

## How Chrome's would

Chrome has no app extension point. It launches a **native messaging host**: a program named in a small JSON file that
Chrome reads from its own folder, talking to it over standard input and output (a 4-byte length, then JSON; at most
1 MB from the host and 64 MB to it). Chrome starts the host when the extension calls `sendNativeMessage` and passes
the calling extension's origin as its first argument.

```
content.js ─► background.js ─► Chrome ─► latchkey-chrome-host (in Latchkey.app/Contents/Helpers)
                                               │ JSON line over a Unix socket
                                               ▼
                                   Broker, gate .chromeExtension (code signature io.snackstud.latchkey.chrome;
                                   ops status, list, set, fill)
```

### The pieces

1. **The extension.** `detector.js` and `content.js` are shared with Safari unchanged; `background.js` and `popup.js`
   get a one-line shim (`globalThis.browser ??= chrome`), because Chrome's MV3 API is `chrome.*` and returns
   promises the same way. The manifest is Safari's plus a pinned `key` so the development build's extension ID is
   stable. The two copies come from one source folder at build time; no fork.
2. **The host, `latchkey-chrome-host`.** A small Swift executable in the package (beside `latchkey` and
   `latchkey-broker`), embedded in `Contents/Helpers` and signed with the identifier `io.snackstud.latchkey.chrome`.
   It does what `SafariWebExtensionHandler.answer` does today. That function moves into `LatchkeyCore` so both
   hosts share one implementation; it is the canonical translator from extension messages to broker requests.
   The host reads one framed message, refuses anything over 64 KB (a saved value is capped at 16 KB already), answers,
   and exits.
3. **The host manifest.** `io.snackstud.latchkey.json`, written to each installed browser's `NativeMessagingHosts`
   folder (for example `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`). Its `path` points at the
   host inside `/Applications/Latchkey.app`, and `allowed_origins` lists only Latchkey's extension IDs (the Chrome Web
   Store ID, and the pinned development ID in development builds only).
4. **The gate.** `Broker.Gate.chromeExtension`, with the same four operations as Safari's. The app admits a
   connection only when the peer's code signature says `io.snackstud.latchkey.chrome` from Latchkey's team, checked
   through the audit token as it is for the CLI and the Safari extension. Approval panels say "Asked by Latchkey for
   Chrome" (or Edge, Brave… from the parent process) and show the page's site.

### Where the socket lives

The direct download listens in `~/Library/Application Support/Latchkey/`. The host gets its own socket there
(`chrome.sock`), not the CLI's, so a gate mistake can't widen what the host may do. The App Store build is out of scope
(below).

## What this adds to the trust boundary

- **A new door, same rooms.** The host can do exactly what the Safari extension can: list names, ask to save, ask to
  fill. Every save and fill shows an approval naming the site; nothing stands in for it. A host that is misused can
  produce approval panels, not values.
- **Who can start the host.** Chrome enforces `allowed_origins`, but any program running as you can also run the host
  binary directly, as it can run the CLI. That's the same boundary as the CLI ([security.md](security.md)). The host
  additionally checks that its parent process is a Chromium browser signed by its vendor (Google, Microsoft, Brave,
  The Browser Company, Vivaldi) and refuses otherwise; this narrows casual misuse and is logged, but it is not
  presented as a security boundary.
- **The page's origin.** As with Safari, the origin comes from the browser through the extension's background script
  (`sender.tab.url`), never from the page. If the extension itself were compromised, it could lie about the origin;
  the approval panel still shows that origin and asks, and fill sites are still decided by the app.
- **The extension's reach.** Its content script runs on all sites, as Safari's does, because keys appear on many
  dashboards; detection runs in the page and sends nothing until you press Save. Chrome's own site access controls
  ("On click", "On specific sites") apply.
- **Updates.** The Chrome Web Store updates the extension on its own schedule. The host checks a protocol version in
  every message and refuses one it doesn't know, so a newer extension and an older app fail clearly.

## Installing it

From **Settings › Developer › Browser Extensions** in the direct download:

- **Chrome (and the other Chromium browsers found on this Mac):** a row per installed browser with **Install**, which
  writes that browser's host manifest and opens the extension's Chrome Web Store page, and **Remove**, which deletes
  the manifest. The row shows "Connected" once the extension has reached the app.
- **Safari:** unchanged (Turn On in Safari…).

`scripts/install.sh` writes the manifests for the development build, pointing `allowed_origins` at the pinned
development ID, and the development extension is loaded unpacked from `build/chrome-extension/`.

Chrome on macOS installs extensions only from the Web Store, apart from unpacked ones in developer mode and ones a
managed policy allows, so release builds need the
Web Store listing.

## Not included

- **The Mac App Store version.** A sandboxed app can't write into Chrome's folders, and the temporary-exception
  entitlement that would allow it is unlikely to pass review. The store build keeps Safari only and says so in
  Settings, linking to the direct download for Chrome.
- **Firefox.** Its native messaging is close to Chrome's (a different manifest folder and `allowed_extensions`), so
  the host could serve it later. Not in the first version.

## Work, in order

1. Move the message translator out of `SafariWebExtensionHandler` into `LatchkeyCore`, with tests; Safari keeps
   working unchanged.
2. Add `latchkey-chrome-host` and `Broker.Gate.chromeExtension`, with tests for framing, size limits, protocol version,
   and the gate refusing other operations and other signatures.
3. Build the Chrome extension from the shared sources; run the existing detector and content tests against it.
4. Settings › Developer › Browser Extensions, and `scripts/install.sh` support.
5. Release: embed and sign the host in `scripts/release.sh`; Chrome Web Store developer account, listing, privacy
   disclosures (all-sites content script, native messaging) and review.
6. Docs: app.md, security.md, privacy policy (a Chrome extension, same data handling), CHANGELOG.

## Decisions needed

- Approve the new identity (`io.snackstud.latchkey.chrome`), the new gate and socket, and the shared translator.
- Which browsers to support in the first version: all Chromium browsers above, or Chrome only.
- Leaving Chrome out of the App Store version.
- The Chrome Web Store account and listing, which are the owner's to set up.
