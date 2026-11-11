# Changelog

## 0.1.0 (unreleased)

The first release.

### Storage and sync
- Values in iCloud Keychain, in Latchkey's own access group, synced to every Mac signed in to your Apple Account.
- Kind, agent-safe, service, note and "used in" travel with each item.
- Settings › **Move to iCloud Keychain** for items saved by an unsigned build.

### Running commands
- `latchkey run` fills in `latchkey://` references and hides values in the command's output.
- `--env PROJECT/ENV` runs without an env file; `--file NAME=ID` and `latchkey-file://` deliver values as temporary
  files.
- Documented exit codes; refusals and missing items say what to do.
- The command-line tool starts the app when it isn't running.

### Agents
- `latchkey mcp`: an MCP server with status, list, check, run and request-grant tools. It never returns a value;
  output is masked and capped, and grants an agent asks for are limited to its folder, a day, and non-production
  environments.
- `latchkey check` shows what a run would get without asking, what would ask, and what's missing.

### Security
- Approvals and grants judge the caller by what the kernel reports: its real working folder and command line, and
  whether it's Latchkey's signed command-line tool. Other programs are named by their path, with a warning.
- Grants live in a keychain item only Latchkey can change, not in a file.
- The command-line tool checks the app's signature before sending anything.
- Development installs no longer carry the debugging entitlement.

### Approvals and grants
- An approval panel with the program chain, folder and command, then Touch ID, Apple Watch or your password.
- Grants for a folder, its subfolders and its repository's worktrees, for up to 7 days; for items, environments or
  projects.
- Agent-safe items for values that aren't secret.

### Organizing
- Items belong to a project's environment (`project/environment/NAME`) or are shared.
- A tree of projects and environments, with counts, environment badges, and where each environment lives.
- Services detected on import; editable.
- Multi-select and project-wide actions, each with one approval.
- Move items between projects and environments, with references updated in their files.

### Importing
- `latchkey import` for one file or many (`--batch`), with one approval, `--rewrite`, `--share-identical`,
  `--agent-safe-pattern`, and expiring Vercel and Turbo tokens skipped by default.
- Projects named after the repository's main checkout; environments from the file name.

### History
- The last 10 values of each item, with show and restore.
- Recently Deleted for 30 days.

### Remote locations
- Link environments to Vercel, GitHub Actions, Railway and Fly; compare names; push with approval every time and an
  extra confirmation for production. Nothing is deployed.

### The app
- Window with sidebar, tree, detail and bulk actions; menu bar panel; settings; open at login.
- A light and dark app icon.
- One copy runs at a time.

### Distribution
- Developer ID-signed and notarized, in a disk image, with the command-line tool inside the app
  (**Latchkey › Install Command Line Tool…**).
