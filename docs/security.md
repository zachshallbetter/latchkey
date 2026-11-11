# Security

Latchkey's job is to keep secret values out of files and transcripts, and to make you the one who decides which
command gets which value. This page says what it protects against, how, and where its protection ends.

## What it protects against

| Risk | How Latchkey handles it |
|---|---|
| Secrets committed, synced or backed up in `.env` files | Files hold references; values live in the keychain. |
| Secrets in an agent's transcript or context | The agent runs commands through `latchkey run`; it sees references and IDs, not values. Output that repeats a value is masked. |
| A program reading a secret you didn't mean to give it | Every read of an item that isn't agent-safe or granted asks you, showing the program chain, folder and command. |
| Losing a value by mistake | Replaced values are kept (last 10); deleted items are restorable for 30 days. |
| Not knowing what read what | Every read, change, grant, move, import and push is logged with the program chain and folder. Stored values are not deliberately logged; arbitrary command arguments use heuristic redaction. |
| Values stolen from a lost or synced device | Values are keychain items: encrypted at rest, and end-to-end encrypted in iCloud Keychain. |
| A value pasted into the wrong dashboard, or a stale value deployed | Remote locations push from one place, ask every time, and need an extra confirmation for production. |

## How it works

- **Storage.** Values are generic-password items in the data-protection keychain, in an access group only the signed
  Latchkey app can use, synced through iCloud Keychain. Versions, remote links, environment records and project links are keychain items too; records
  and links hold item IDs, remotes and plain settings, nothing secret (plain settings that look secret are refused). Synced
  items use the "after first unlock" protection class, so scheduled jobs can read agent-safe items while the screen
  is locked.
- **One process holds values.** The command-line tool never touches the keychain. It asks the app over a Unix socket
  (`~/Library/Application Support/Latchkey/broker.sock`, readable and writable only by you). The app accepts
  connections only from your user account.
- **The tool checks the app.** Before sending anything, a signed `latchkey` checks that the program on the socket is
  the Latchkey app signed by the same team, so a program that took the socket while the app wasn't running gets
  nothing, not even a value you're saving. (An unsigned development build can't check and doesn't.)
- **The app checks who asks, from the kernel.** For each connection the app gets the caller's identity from the
  kernel, not from the request: its working folder, its command line, its parent processes, and whether it is
  Latchkey's own command-line tool, by code signature. The approval panel and the log show those. Any other program
  talking to the socket is named by its path, with a warning. Grants are matched against the folder the caller
  really runs in.
- **Approvals** use macOS LocalAuthentication: Touch ID, a paired Apple Watch, or your account password. Releasing values
  shows the panel with the caller's folder, command and process chain before Touch ID. A change asks with the system
  sheet alone, naming the item, the agent and the folder; its Details… button shows the rest. A request over SSH or
  from a program that isn't Latchkey's tool always shows the panel and its warning first. Nothing unanswered is
  allowed: either prompt denies after 90 seconds. Allow Once authorizes one request; approvals are never cached.
- **Grants** are kept in a keychain item only Latchkey can read or change, on this Mac only, and last at most 7 days.
  No file holds them, so no other program can write itself one.
- **The key proxy** (`latchkey run --proxy`) keeps OpenAI and Anthropic keys in the signed `latchkey` process, which
  other programs can't read. The command gets a random placeholder; the proxy listens on 127.0.0.1 only, refuses
  requests without that run's placeholder, and sends the real key only to the provider's own host.
  It refuses custom base URLs, plaintext supported keys and duplicate variable or file deliveries of a protected
  key. It never follows upstream redirects. Other credentials are delivered normally.
- **Short-lived AWS credentials** (`--aws-session`, `--aws-role`) are minted by STS with the long-lived key, which
  stays in `latchkey run`; the command gets credentials that expire in 15 minutes by default.
- **The Safari extension** is sandboxed and reaches the app through its own socket in the App Group container
  both share. The app admits only Latchkey's signed extension there (checked by code signature), and only to list
  item names, save a value, which asks like any change, and fill one item into the page you're on. Fill asks every
  time (no grant, recent approval or agent-safe setting stands in), works only on the item's own fill sites if it has any, else
  its service's own site and deployment platforms (decided by the app from the origin Safari reports, https only, never in a frame), and is
  logged. Otherwise it can't read a stored value. The page's site it reports is
  shown in the approval as Safari reported it. Its key detection runs inside the page: a value goes to the app only
  when you press Save, and its toolbar panel gets a short preview, never the value. Password fields are not read. Fields that expect a key are recognized by their labels and attributes only.
  Detection covers the main page DOM, not embedded frames or shadow roots.
  Use Safari’s website permissions to choose which sites the extension may inspect.
- **Exporting values** (`latchkey export --values`) asks every time, naming the file, and nothing stands in for that
  approval. The file is written beside its destination, readable only by you, and renamed into place, so an existing
  file isn't touched until the new one is complete; a symbolic link at the destination is refused. The access log
  records the items and the file, never the values. Agents through `latchkey mcp` can't export values.
- **Project links** match a checkout to a project by its Git remotes. A match only names the project; it never
  releases a value or widens a grant, so pointing a repository's `origin` at another project's remote gains nothing
  without your approval. A match through a remote other than `origin` is flagged.
- **Temporary key files** live in a new folder only you can open, are only readable by you, and are deleted when the
  command exits. Different item IDs use different temporary files, even when their final names match.
- **Remote pushes** pass values to each service's tool on standard input, never as arguments, so they don't appear
  in process listings. No service tokens are stored.
- **Logs and errors** avoid recording values from the store. Tool errors are shortened and have any value replaced. Command lines in
  the log, the approval panel and the system sheet have likely secrets replaced with `<redacted>` (values after
  `--token` and similar, `NAME=VALUE` where the name says it's secret, Authorization headers, known token prefixes,
  long random-looking strings, and credentials in URLs). This is heuristic redaction of arbitrary command lines,
  not a guarantee: keep secret values out of command arguments.
- **The log is tamper-evident.** Each entry carries a keyed hash (HMAC-SHA256) of itself and the one before it. The
  key, and the hash and count of the latest entry, are keychain items only Latchkey can read, so `latchkey log
  --verify` finds an entry that was changed, removed or added, or a log cut short. It can't stop a program running as
  you from deleting the file, only show that it happened.

## Where protection ends

Be clear about these before you rely on Latchkey:

- **Anything running as you can ask.** The socket is open to every process in your user account. Latchkey can't tell
  a program you trust from one you don't, except by the process chain it shows you. Agent-safe items and grants are
  released to any program that asks from the right place, so keep them narrow and short.
- **The caller chain is informative, not proof.** The caller itself is checked by signature, but its parents are
  named by their files, and file names can be faked. Judge a request by its folder and
  command as well, and deny anything unexpected.
- **A released value is out of Latchkey's hands.** Once a command has a value, it can write it to a file, send it
  over the network, or transform it. Masking only hides exact copies of values 6 characters or longer in what the
  command prints; it doesn't stop a command that tries to leak.
- **An exported file is a plain copy.** After `latchkey export --values`, the file holds the values; delete it when
  you're done, and keep it out of Git. The file named in the approval is the one the command says it will write.
- **`latchkey get` prints the value.** Keep agents away from it (your agent instructions, or a hook that refuses it).
- **The same Mac account.** Malware running as you could also ask for approvals until you click one, or read a
  temporary key file while the command runs. Latchkey raises the bar; it doesn't replace a clean machine.
- **History keeps old values.** That's what makes restore work, but an old value stays readable (with your approval)
  for up to 30 days after deletion, or until it's one of more than 10 versions. Use **Forget History** when an old
  value shouldn't linger, and rotate leaked keys at the service either way.
- **Unsigned builds** fall back to the login keychain on one Mac. Each rebuild changes the build's identity, so macOS
  asks for your login password the first time a new build reads each item.
- **iCloud Keychain** protection is Apple's: anyone who controls your Apple Account and a trusted device can reach
  synced items.

## Reporting a problem

Report security issues privately, as [SECURITY.md](../SECURITY.md) describes, rather than in a public issue.
