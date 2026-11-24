# Security

Pistachio's job is to keep secret values out of files and transcripts, and to make you the one who decides which
command gets which value. This page says what it protects against, how, and where its protection ends.

## What it protects against

| Risk | How Pistachio handles it |
|---|---|
| Secrets committed, synced or backed up in `.env` files | Files hold references; values live in the keychain. |
| Secrets in an agent's transcript or context | The agent runs commands through `pst run`; it sees references and IDs, not values. Output that repeats a value is masked. |
| A program reading a secret you didn't mean to give it | Every read of an item that isn't agent-safe or granted asks you, showing the program chain, folder and command. |
| Losing a value by mistake | Replaced values are kept (last 10); deleted items are restorable for 30 days. |
| Not knowing what read what | Every read, change, grant, move, import and push is logged with the program chain and folder. Stored values are not deliberately logged; arbitrary command arguments use heuristic redaction. |
| Values stolen from a lost or synced device | Values are keychain items: encrypted at rest, and end-to-end encrypted in iCloud Keychain. |
| A value pasted into the wrong dashboard, or a stale value deployed | Remote locations push from one place, ask every time, and need an extra confirmation for production. |

## How it works

- **Storage.** Values are generic-password items in the data-protection keychain, in an access group only the signed
  Pistachio app can use, synced through iCloud Keychain. Versions, remote links, environment records and project links are keychain items too; records
  and links hold item IDs, remotes and plain settings, nothing secret (plain settings that look secret are refused). Synced
  items use the "after first unlock" protection class, so scheduled jobs can read agent-safe items while the screen
  is locked.
- **One process holds values.** The command-line tool never touches the keychain. It asks the app over a Unix socket
  (`~/Library/Application Support/Latchkey/broker.sock`, readable and writable only by you). The app accepts
  connections only from your user account.
- **The tool checks the app.** Before sending anything, a signed `pistachio` checks that the program on the socket is
  the Pistachio app signed by the same team, so a program that took the socket while the app wasn't running gets
  nothing, not even a value you're saving. (An unsigned development build can't check and doesn't.)
- **The app checks who asks, from the kernel.** For each connection the app gets the caller's identity from the
  kernel, not from the request: its working folder, its command line, its parent processes, and whether it is
  Pistachio's own command-line tool, by code signature. The approval panel and the log show those. Any other program
  talking to the socket is named by its path, with a warning. Grants are matched against the folder the caller
  really runs in.
- **Approvals** use macOS LocalAuthentication: Touch ID, a paired Apple Watch, or your account password. Every request
  shows Pistachio's panel with what it covers, the caller's folder, command and process chain; Touch ID is evaluated
  inside the panel (`LAAuthenticationView`, biometrics only), and **Use Password…** falls back to the system sheet.
  Touch ID runs in the Secure Enclave either way: another app drawing a lookalike panel gets a touch that authorizes
  nothing in Pistachio. Requests from the same process tree in the same folder (each parent's process ID and start
  time, from the kernel) that arrive while the panel is up are listed in it as rows and answered by one touch; a row
  joining restarts Touch ID. Pushes, requests over SSH, from Pistachio for Safari or from a program the kernel couldn't
  identify are never grouped. Nothing unanswered is allowed: a request denies after two minutes. Allow Once authorizes
  one request; approvals are never cached.
- **Approval waits outside the broker lock.** A request that needs approval runs once to find its question, waits
  for the answer without holding the broker, then runs again from the start. It uses the answer only if it asks the
  same question (for releasing values, the same or fewer of the same items) and each item's value is unchanged (a
  SHA-256 of each value, kept in memory only for the wait). Otherwise it asks again, three times at most, then
  refuses. An approver that can show only one question at a time, the system sheet, is still asked one at a time.
- **The app lock** hides the window, Settings and the menu bar panel behind a lock screen (Touch ID or the Mac
  password) at launch, after time in the background, and on sleep or screen lock; nothing behind it is drawn, and
  revealed values are hidden. It's a privacy screen for the window, not an authorization step: requests from
  commands, agents and Safari go through approval whether it's locked or not, and unlocking releases nothing.
- **Grants** are kept in a keychain item only Pistachio can read or change, on this Mac only. They last as long as the
  approval says: a time of any length, until the agent quits, or until revoked (no end date; stored with the farthest
  possible end so earlier versions read it as unexpired). There is no maximum: a grant until revoked keeps working
  until you revoke it in Grants or with `pst revoke`, so it's the one to review.
  No file holds them, so no other program can write itself one.
- **The key proxy** (`pst run --proxy`) keeps OpenAI and Anthropic keys in the signed `pistachio` process, which
  other programs can't read. The command gets a random placeholder (122 bits from the system generator, new each
  run); the proxy listens on 127.0.0.1 only, on a port the system picks, refuses requests without that run's
  placeholder, and sends the real key only to the provider's own host.
  It refuses custom base URLs, plaintext supported keys and duplicate variable or file deliveries of a protected
  key. It never follows upstream redirects. Other credentials are delivered normally.
  The placeholder is a bearer token, and macOS lets any program running as you read another same-user program's
  environment (`ps eww`, `sysctl KERN_PROCARGS2`), apart from some Apple-protected binaries. So the placeholder alone
  isn't trusted: a request is also served only if its connection comes from the command or a process it started.
  The proxy finds the process holding the client end of each connection in the kernel's socket table, requires every
  holder to descend from the command (matching process ID and start time, so a reused ID never qualifies), and
  refuses the request if no holder is found or the table can't be read. A program that reads the placeholder from
  the environment and connects to the port gets a 403. The proxy stops, and cancels open connections, the moment
  the command exits.
  `--proxy-models A,B` refuses any request whose JSON body doesn't name exactly one of those models (no body,
  compressed or malformed JSON, a repeated `model` key, and requests like `GET /v1/models` are all refused), and
  `--proxy-requests N` refuses requests after N have been forwarded, across both providers; refused requests aren't
  counted. `pst run` prints a proxy-limits notice on standard error when either is set.
  What the proxy doesn't protect:
  - The command and everything it starts can use the key, within those limits. A descendant that detaches (a
    daemon that launchd adopts) is no longer served, and neither is a server that was already running.
  - Beyond the model name, the proxy doesn't look inside requests: the command can send any prompt or file to the
    provider, and spend is capped only by `--proxy-requests`, not by tokens or money. Without `--proxy-models` it
    doesn't restrict paths or methods on the provider's API.
  - A descendant can relay requests for an outsider, and a program running as you that can attach a debugger to
    the command or read its memory gets whatever the command has. That is the same boundary as the rest of this page.
  - The placeholder can still appear in the command's output or logs. It is useless outside the tree, but it
    isn't concealed.
- **Short-lived AWS credentials** (`--aws-session`, `--aws-role`) are minted by STS with the long-lived key, which
  stays in `pst run`; the command gets credentials that expire in 15 minutes by default.
- **The Safari extension** is sandboxed and reaches the app through its own socket in the App Group container
  both share. The app admits only Pistachio's signed extension there (checked by code signature), and only to list
  item names, save a value, which asks like any change, and fill one item into the page you're on. Fill asks every
  time (no grant, recent approval or agent-safe setting stands in), works only on the item's own fill sites if it has any, else
  its service's own key page host and deployment platforms' dashboards, never a customer-hosted subdomain (decided by the app from the origin Safari reports, https only, never in a frame), and is
  logged. Otherwise it can't read a stored value. The page's site it reports is
  shown in the approval as Safari reported it. Its key detection runs inside the page: a value goes to the app only
  when you press Save, and its toolbar panel gets a short preview, never the value. Password fields are not read. Fields that expect a key are recognized by their labels and attributes only.
  Detection covers the main page DOM, not embedded frames or shadow roots.
  Use Safari’s website permissions to choose which sites the extension may inspect.
- **Exporting values** (`pst export --values`) asks every time, naming the file, and nothing stands in for that
  approval. The file is written beside its destination, readable only by you, and renamed into place, so an existing
  file isn't touched until the new one is complete; a symbolic link at the destination is refused. The access log
  records the items and the file, never the values. Agents through `pst mcp` can't export values. Inside a Git
  checkout the file must be ignored and untracked, checked before anything is asked. `--merge` changes only the
  variables Pistachio manages in an existing file and refuses one that changes while an approval waits.
- **Copying an environment** (`pst export --values --clipboard`, and **Copy as .env** in the app) asks every
  time, naming the environment and the clipboard. The values stay on this Mac, are marked so clipboard managers skip
  them, and are cleared after 60 seconds. The log records "copied to the clipboard", never the values. Agents,
  Safari and requests forwarded over SSH can't copy. Unlike a file, a copy can't be traced afterwards.
- **Copied values** go to this Mac's clipboard only, not to your other devices, are marked so clipboard managers skip
  them, and are cleared after 60 seconds.
- **Project links** match a checkout to a project by its Git remotes. A match only names the project; it never
  releases a value or widens a grant, so pointing a repository's `origin` at another project's remote gains nothing
  without your approval. A match through a remote other than `origin` is flagged.
- **Temporary key files** live in a new folder only you can open, are only readable by you, and are deleted when the
  command exits. Different item IDs use different temporary files, even when their final names match.
- **Remote pushes** pass values to each service's tool on standard input, never as arguments, so they don't appear
  in process listings. No service tokens are stored. A link can instead name an item that holds the service's access
  token (always, in the App Store build): the push then sends values over HTTPS straight to that service's API
  (`api.vercel.com`, `api.github.com`, `backboard.railway.com`, `api.machines.dev`, fixed in the code, no redirects),
  with the token as a bearer token, and only after the approval that names the token item. The token is read inside the
  app for the request and for `remote status` (which returns names only), is never returned to a caller, logged or put
  in a URL, and the item can't be one of the values that link pushes. Responses are size-capped, checked, and never
  quoted in errors. Pistachio itself holds a token only as an ordinary item, so it has the item's protections and the
  token's reach: use one limited to the project you push.
- **Logs and errors** avoid recording values from the store. Tool errors are shortened and have any value replaced. Command lines in
  the log and the system sheet have likely secrets replaced with `<redacted>` (values after
  `--token` and similar, `NAME=VALUE` where the name says it's secret, Authorization headers, known token prefixes,
  long random-looking strings, and credentials in URLs). This is heuristic redaction of arbitrary command lines,
  not a guarantee: keep secret values out of command arguments. The approval panel shows what a signed
  `pst run` starts in full, unredacted, so the program being given values is never hidden from the person
  approving it, and it lists every item asked for with a count.
- **The log is tamper-evident.** Each entry carries a keyed hash (HMAC-SHA256) of itself and the one before it. The
  key, and the hash and count of the latest entry, are keychain items only Pistachio can read, so `pistachio log
  --verify` finds an entry that was changed, removed or added, or a log cut short. It can't stop a program running as
  you from deleting the file, only show that it happened.
- **Finding duplicates.** `pst duplicates` and **Find Duplicates…** compare values inside the app and return only which
  items match. Which items share a key is still worth knowing, so it asks every time and agents can't ask.

## Where protection ends

Be clear about these before you rely on Pistachio:

- **Anything running as you can ask.** The socket is open to every process in your user account. Pistachio can't tell
  a program you trust from one you don't, except by the process chain it shows you. Agent-safe items and grants are
  released to any program that asks from the right place, so keep them narrow and short.
- **The caller chain is informative, not proof.** The caller itself is checked by signature, but its parents are
  named by their files, and file names can be faked. Judge a request by its folder and
  command as well, and deny anything unexpected.
- **A released value is out of Pistachio's hands.** Once a command has a value, it can write it to a file, send it
  over the network, or transform it. Masking only hides exact copies of values 6 characters or longer in what the
  command prints; it doesn't stop a command that tries to leak.
- **An exported file is a plain copy.** After `pst export --values`, the file holds the values; delete it when
  you're done, and keep it out of Git. The file named in the approval is the one the command says it will write.
- **`pst get` prints the value.** Keep agents away from it (your agent instructions, or a hook that refuses it).
- **The same Mac account.** Malware running as you could also ask for approvals until you click one, or read a
  temporary key file while the command runs. Pistachio raises the bar; it doesn't replace a clean machine.
- **History keeps old values.** That's what makes restore work, but an old value stays readable (with your approval)
  for up to 30 days after deletion, or until it's one of more than 10 versions. Use **Forget History** when an old
  value shouldn't linger, and rotate leaked keys at the service either way.
- **Unsigned builds** fall back to the login keychain on one Mac. Each rebuild changes the build's identity, so macOS
  asks for your login password the first time a new build reads each item.
- **iCloud Keychain** protection is Apple's: anyone who controls your Apple Account and a trusted device can reach
  synced items.

## Reporting a problem

Report security issues privately, as [SECURITY.md](../SECURITY.md) describes, rather than in a public issue.

## Chrome and Firefox native connection

Local development builds use a separate `browser.sock` listener in the existing App Group container. Its
`.browserExtension` gate authenticates `io.snackstud.pistachio.browser` from the app’s signing team through the
peer audit token and permits only `status`, `list`, `set` and `fill`. Every save/fill asks; agent-safe flags,
CLI grants and grouped approvals do not bypass browser approval. The broker checks allowed fill sites again.
The shared translator exposes no general request forwarding or export operation.

The native helper accepts versioned, length-prefixed JSON (64 KiB input, 1 MiB output), refuses truncated frames
and unlisted Chrome/Firefox extension arguments, and checks the parent browser’s vendor signature. Browser host
manifests restrict allowed extensions. These checks supplement per-action approval; they do not attest that an
extension is uncompromised. Page origins come from the browser background’s sender context. A compromised extension
could misrepresent that context, so the displayed origin and app approval remain essential.

The setup script verifies the app/helper signature before writing native-host manifests. A private, owner-only
allowlist in the shared container records public extension IDs. Removal leaves vault contents untouched. Browser
permissions remain under the user’s control. Installed-browser status connectivity is verified; live save/fill and signed sandbox runtime verification remain pending;
see [connection setup and limitations](chrome-extension.md). No extension-store release is implied by a local build.

### Browser detection context

Credential detection and suggested naming use bounded local field labels, nearby groups, page title/path and exact
provider-dashboard hints. Whole-body wording, randomness or a provider hostname alone is insufficient. Negative
labels (request IDs, public keys, checksums, examples) take precedence over generic credential cues; public envelopes
stay public. Provider hints and confidence never authorize a fill or replace the broker’s origin/approval checks.
No network validity checks are performed, and titles/paths/nearby text are not added to native broker requests.
Query strings and fragments are excluded from classification context. See [detection behavior](chrome-extension.md#context-aware-detection).
