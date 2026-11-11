# Concepts

## Items and IDs

An **item** is one value with a name and a few settings. Its **ID** says where it belongs:

| ID | Kind of item |
|---|---|
| `GEMINI_API_KEY` | **Shared**: one value, usable from any project |
| `shop/production/DATABASE_URL` | Belongs to the `production` environment of the `shop` project |

Each part uses letters, digits, `_`, `-` and `.`, up to 64 characters. The ID is the only place the project and
environment are stored, so grouping always matches what files refer to.

## References

Files and environment variables refer to items with `latchkey://` followed by the ID:

```
DATABASE_URL=latchkey://shop/production/DATABASE_URL
GEMINI_API_KEY=latchkey://GEMINI_API_KEY
REDIS_URL=redis://default:latchkey://shop/production/REDIS_PASSWORD@cache.example.com:6379
```

A reference can be the whole value or part of one. `latchkey run` fills them in when the command starts. A value of
the form `latchkey-file://ID` is different: the command gets the path of a temporary file holding the value (see
[key files](#key-files)).

## Projects, environments and services

- A **project** is usually a repository. Import names it after the repository's folder (a worktree counts as its
  main checkout).
- An **environment** is one set of values for a project: `development`, `preview`, `production`, or any name you
  like (`pr-123`, `eu-west`). development, preview, staging, production and test get their own colours and sort
  first.
- When a service needs different values from your laptop, give it its own environment: `shop/vercel.preview` beside
  `shop/preview`. The app shows `vercel.preview` as "Vercel · preview".
- A **service** is who issued a value: Neon, Stripe, GitHub. It's a label, not part of the ID, so changing it never
  breaks a reference. Import fills it in where it can tell.

## Kinds

| Kind | For | Shown in command output |
|---|---|---|
| Token | API keys and access tokens | Hidden |
| Password | Passwords and connection strings | Hidden |
| Key file | SSH, GPG, `.p8`, `.pem` | Hidden |
| Plain value | Host names, regions, account IDs | Shown |

## Approvals

Reading an item asks you, unless it's agent-safe or covered by a grant. The approval panel shows:

- the items,
- the program asking and its parents (for example `zsh › claude`),
- the folder it's running in,
- the command it's about to start.

Choose **Deny**, **Allow Once**, or **Allow from this folder for** 1 hour, 8 hours, 1 day or 7 days. Touch ID, a
paired Apple Watch or your Mac password then confirms your choice. Requests you make in the Latchkey window go
straight to Touch ID.

A panel nobody answers counts as a denial after 90 seconds. **Allow Once** authorizes one read request.
Approvals are not cached; repeated access needs an explicit grant or an item set to allow reads without approval.

Changes (saving, deleting, moving, importing) always ask.

## Agent-safe items

The app calls this **No Approval**; the CLI option and protocol field remain `--agent-safe` and `agentSafe`.
Any program in your Mac account can request these values without approval. Use it for values that aren't
really secret or that end up public anyway: a public API URL, a `NEXT_PUBLIC_*` key that ships in a browser bundle.
Everything else should ask.

## Grants

A **grant** lets commands run from one folder read some items without asking, until it ends:

- It covers the folder, the folders inside it, and that repository's git worktrees wherever they live.
- It names items, or a whole environment (`shop/development/*`) or project (`shop/*`), including items added later.
- It lasts at most 7 days. Revocation stops future reads through that grant immediately; another grant or
  a No Approval setting may still permit access. Revocation cannot recall values a process already received.
- It's kept on this Mac only.

Make one from the approval panel (**Allow from this folder for…**), from **Grants** in the app, or with
`latchkey grant`. Grants are how you leave an agent working without being at your Mac.

## History

When a value changes, the old one is kept as a version, with when and by whom. Each item keeps its last 10
versions. Deleting an item keeps its value in **Recently Deleted** for 30 days. Showing an earlier value or restoring
one always asks; grants and agent-safe don't cover history.

## Remote locations

An environment can be linked to the places that hold its values outside your Mac: a Vercel project's environment,
a repository's GitHub Actions secrets, a Railway service, a Fly app. Latchkey can compare names with them and push
values to them. See [Remote locations](remote.md).

## Key files

Some tools want a file, not a value: App Store Connect `.p8` keys, a gcloud service-account JSON. `latchkey run --file
NAME=ID` (or `NAME=latchkey-file://ID` in an env file) writes the value to a temporary file only you can read, sets
`NAME` to its path, and deletes the file when the command exits.

## Where things live

| What | Where |
|---|---|
| Values, versions, links | iCloud Keychain (in Latchkey's own access group), synced to your Macs |
| Kind, agent-safe, service, note, the files an item was imported from | With the item, synced |
| Grants | A keychain item only Latchkey can change ("Latchkey grants"), this Mac only |
| Activity log (never values) | `~/Library/Application Support/Latchkey/access.jsonl`, this Mac only |
| The connection between the command-line tool and the app | `~/Library/Application Support/Latchkey/broker.sock` |

Latchkey's items don't appear in the Passwords app, and it can't read the Passwords app's entries; see
[Apple Passwords and passkeys](apple-passwords-and-passkeys.md).
