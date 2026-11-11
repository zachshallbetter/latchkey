# Remote locations

Link an environment to the places that hold its values outside your Mac, then check and push from Latchkey instead
of pasting into each dashboard.

| Service | Target | Tool used |
|---|---|---|
| Vercel | a project's development, preview or production (optionally one preview Git branch) | `vercel` |
| GitHub Actions | a repository's secrets, or a GitHub environment's | `gh` |
| Railway | a service in an environment | `railway` |
| Fly | an app's secrets | `flyctl` |

Latchkey runs each service's own command-line tool, signed in as you. It stores no service tokens. Install and sign
in to the tools you use (`vercel login`, `gh auth login`, `railway login`, `flyctl auth login`).

## Linking

```bash
latchkey remote link shop/vercel.preview vercel project=shop environment=preview
latchkey remote link shop/production github repo=me/shop environment=production
latchkey remote link shop/railway.production railway environment=production service=api dir=~/Projects/shop
latchkey remote link shop/production fly app=shop-api
```

| Key | Used by | Meaning |
|---|---|---|
| `project` | Vercel, Railway | Vercel project name or ID; Railway project ID |
| `environment` | Vercel, GitHub, Railway | Vercel: development, preview or production. GitHub: a GitHub environment (leave out for repository secrets). Railway: the environment |
| `repo` | GitHub | `owner/repo` |
| `service` | Railway | The service |
| `app` | Fly | The app |
| `branch` | Vercel preview | One Git branch |
| `dir` | Vercel, Railway | A folder linked with `vercel link` or `railway link`, instead of `project` |

Linking asks for approval. A link covers the whole environment, including items added later. In the app: right-click
an environment › **Remote Locations…** › **Add a Location…**.

When a service needs different values from your laptop, give it its own environment (`shop/vercel.preview` beside
`shop/preview`) and link that.

## Checking

```bash
latchkey remote status shop/production
```

For each link: names missing there, names only there, and items whose value changed since they were last pushed.
Status reads names only. (Railway's listing includes values; Latchkey keeps the names and discards the rest.)

## Pushing

```bash
latchkey push shop/production --dry-run
latchkey push shop/production
latchkey push shop/production --to <link> --only shop/production/DATABASE_URL
```

- Every push asks, every time. No grant or remembered approval covers a push.
- Production targets (Vercel production, a GitHub or Railway environment named like production, and Fly apps unless
  their name says staging, preview or dev) need **I mean to change production** ticked in the panel before you can
  approve.
- Pushes run only in the app.
- Values go to each tool on standard input, never as command arguments:

  | Service | Command |
  |---|---|
  | Vercel | `vercel env add NAME --environment ENV --force --yes` (secret kinds are stored as Sensitive outside development) |
  | GitHub | `gh secret set NAME --repo OWNER/REPO [--env ENV]` |
  | Railway | `railway variable set NAME --stdin --skip-deploys` |
  | Fly | `flyctl secrets import --stage --app APP` (one line per value; multi-line values aren't supported) |

- **Nothing is deployed.** Railway and Fly would deploy by default, so those flags turn it off. New values take effect
  on the service's next deploy, which you start.
- Each item is named after the last part of its ID (`shop/production/DATABASE_URL` is pushed as `DATABASE_URL`).
- Error messages from the tools are shortened, and any value in them is replaced with `<value>`.

After a push, Latchkey records when each item was pushed to each link. An item changed since then shows an orange badge
in the list and "Changed since last push" in its detail.

## Unlinking

```bash
latchkey remote unlink <link>
```

Values already at the service stay there; Latchkey stops tracking and pushing. Unlinking doesn't ask.
