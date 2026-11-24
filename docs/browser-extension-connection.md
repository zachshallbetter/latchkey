# Chrome and Firefox connection decision

Status: owner approved on November 23, 2026: “Approve the proposed connection.” Implemented locally; installed-browser status connectivity verified in Chrome and Firefox; live save/fill and signed sandbox runtime verification remain pending. See [build and setup](chrome-extension.md).
Parent: owner requested Chrome and Firefox versions after accepting Safari branding.

## Intended behavior

Share the existing detector, save/fill controls, popup and Pistachio artwork. Chrome uses a Manifest V3 service
worker; Firefox uses a Manifest V3 background script. Detection stays inside the page. The app still asks for
approval on every save and fill and checks the page origin itself. No passwords or keys are bundled in packages.

## Approved owner decision

- One helper executable, `pistachio-browser-host`, signed as `io.snackstud.pistachio.browser` by the app’s existing
  team. Native messaging host name: `io.snackstud.pistachio`. Keep the existing Safari identity and endpoint.
- One new restricted broker listener, `browser.sock`, inside the existing shared App Group container. Admit only
  that signed helper from the same team. Allowed broker operations: `status`, `list`, `set`, `fill`; no CLI-wide API,
  exports, grants, clipboard or generic execution. Caller presentation must identify Chrome or Firefox clearly.
- Move Safari’s existing message-to-request translation into shared core code so neither browser gains additional
  operations. The browser background supplies the top-level origin, never the page’s claimed origin. Browser/frame
  information is checked; the app remains the final site-allowlist and approval authority.
- Native input/output uses bounded length-prefixed JSON, with a protocol version, a 64 KiB input limit, a 1 MiB
  output limit, complete-frame checks and no values on stderr or process arguments. Malformed requests fail closed.
- Chrome host registration allows only explicitly configured extension IDs. Development builds do not invent a
  store ID: load the unpacked build, copy its ID and supply that ID to setup. Firefox has a stable development
  add-on ID, `pistachio@snackstud.io`; its host manifest allows that ID only. Store IDs are separate release inputs.
- The helper rejects unlisted extension arguments. Browser-parent signature checks supplement the restrictions;
  these do not make a compromised local extension trustworthy. The app’s per-action approvals remain essential.
- Keep existing bundle IDs, Keychain groups and stored references. Target the same App Group design for direct
  and sandboxed builds. Sandbox setup requires user-selected access to browser registration folders; do not
  silently remove functionality or claim App Store runtime parity before signed sandbox verification.

## Exclusions and recovery

No extension-store publication, purchases, new signing credentials or extra browser/site permission grants.
Registration writes only the selected browsers’ native-host manifests and can be removed without changing vault
contents. New listeners and packaged helper are additive; Safari stays on its existing endpoint. Tests must prove
rejection of wrong identities/operations, malformed frames, oversized messages and unapproved releases.

## Independent packages

Chrome and Firefox development artifacts can be built and inspected before approval. Until the native helper is
implemented, signed and explicitly registered, their popup must explain that the app connection is unavailable;
these artifacts alone are not a functioning vault integration. Firefox production installation additionally needs
Mozilla signing; Chrome distribution needs its store release workflow. Building is not publication.

## References

- [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Firefox native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)
- [Firefox background contexts](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background)
- [Firefox browser-specific manifest settings](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/browser_specific_settings)
