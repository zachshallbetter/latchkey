# The app

Latchkey is a regular Mac app with a window and a menu bar icon. It also answers the command-line tool, so it needs
to be running for `latchkey run` to work (the tool starts it if it isn't). Only one copy runs at a time.

## The window

### Sidebar

- **All**, **No Approval**, **Ask First** and **Activity**, each with a count.
- **Kinds**: tokens, passwords, key files and plain values.
- **Projects**: one row per project, with a filter field once you have more than eight. **Shared** holds items that
  belong to no project.
- **Services**: items by the service that issued them.
- **Access**: **Grants** and **Recently Deleted**.
- At the bottom, where values are kept: **iCloud Keychain** or **This Mac only**.

### The list

Items are shown as a tree: project, then environment, then items. In a project's own view the tree starts at its
environments. Groups start closed; a closed project shows how many items it has and which environments, and a closed
environment shows where its values live (**Local**, **Not linked**, or the services it's linked to). While you
search, groups start open.

Badges on an item: a green shield for agent-safe, an orange arrow when its value changed since it was last pushed to a
remote location, a crossed-out cloud when it hasn't been pushed there yet.

Right-click a project or environment header to act on everything in it: select all, require approval or let agents
read, grant access, move, delete, and (for an environment) **Remote Locations…**.

### Selecting several items

⌘-click or ⇧-click to select several. The detail pane becomes a summary with actions for all of them: require
approval or let agents read, set the kind or service, move, grant access, delete. Each action asks for Touch ID once.
Right-clicking the selection offers the same.

### An item's detail

- **Value**: hidden. The eye shows it for 30 seconds; the copy button copies it and clears the clipboard after 60
  seconds (and marks the copy so clipboard managers skip it). Both ask unless the item is agent-safe.
- **Reference**: the `latchkey://` text to paste into a file.
- **Change Value…**, **Kind**, **Allow reads without approval**, **Project** (with **Move…**), **Service**,
  **Note**.
- **Remote**: where the item stands at each linked location.
- **Readable Without Asking**: grants that cover it, with **Revoke**.
- **Used In**: the files it was imported from.
- **History**: earlier values with show and restore; **Forget History…** deletes them for good.
- **Recent Activity**, and **Delete…** (the item moves to Recently Deleted for 30 days).

### Adding and importing

- **+ › New Item…** (⌘N).
- **File › Import .env File…** (⇧⌘I), or drop a file on the window. The sheet proposes the project and environment,
  lists each key with its kind and agent-safe setting, marks keys that already exist, and lists lines it leaves alone
  (empty, already references, or expiring Vercel and Turbo tokens). Import asks once. **Replace values in the file
  with latchkey:// references** rewrites the file afterwards.

### Moving

**Move to a Project…** (item menu, detail pane, or **+**): pick items, a project and environment (or Shared), and the
files whose references should follow. Items keep their values, settings and history.

### Grants

What each grant covers and when it ends. **New Grant…** makes one ahead of time; **Revoke** and **Revoke All** end
them.

### Recently Deleted

Items deleted in the last 30 days, with how long each has left. **Restore** brings an item back with its settings;
**Forget for Good…** deletes it and its history.

### Remote Locations

Right-click an environment › **Remote Locations…**: its links, **Check Status** (names only), **Push** to one or all,
and **Add a Location…**. See [Remote locations](remote.md).

## The approval panel

Appears when a program needs your approval. It shows the items, the program asking, its folder and command. On a Mac
with Touch ID it's one step: touch the sensor to allow once, or tick **Allow from this folder** (for a time, until the
agent quits, or only for this command) first; **Deny** refuses. Without Touch ID, choose with the buttons and confirm
with your password. Pushes always use the buttons, since production needs **I mean to change production** ticked
first. Things you start yourself, in the window or in Latchkey for Safari, skip the panel and ask for Touch ID alone.
See [Concepts](concepts.md#approvals).

After an import or a new item, Latchkey shows what to do next: the reference to put in your env file and the
`lk run` command for that folder, ready to copy.

## The menu bar

Click the key: search your items, copy a value, open an item in the window, open Settings, or quit.

## Settings

- **Storage**: where values are kept, and **Move to iCloud Keychain** for items saved before the app was signed.
- **Approval**: how you approve (Touch ID, Apple Watch, password), and the difference between one-request approvals and explicit grants.
- **General**: **Open Latchkey at login**, **Install Command Line Tool** (release builds; links `latchkey` and `lk`), and the activity log in
  Finder. **Latchkey › Install Command Line Tool…** in the menu bar does the same.

## Latchkey for Safari

Latchkey comes with a Safari extension that spots a new key on the page where you made it and saves it when you say
so. It recognizes the formats of about twenty providers (Stripe, OpenAI, Anthropic, GitHub, GitLab, Slack, Google,
npm, Hugging Face and others), private keys, database URLs with a password, and long random values labelled as a
secret or token. It skips what isn't secret or isn't a real key: masked values, examples, publishable keys,
certificates, commit hashes.

- When a page shows a new key and says it won't show it again, the save panel opens from its button on its own, once;
  press **Save to Latchkey** (or Return) to save it, or **Not now**.
- For stronger matches, a **Save to Latchkey** button appears beside the key. Press it, choose where it goes (shared, or a
  project's environment; a live or test key is matched to production or development when it can be) and its name,
  then **Save to Latchkey**.
- Less certain finds aren't marked on the page: the toolbar button shows how many it spotted, and its panel lists them
  (a short preview, never the value) so you can open the save panel for one.
- For anything it missed, select the text, Control-click, and choose **Save Selection to Latchkey**.

The app asks you to approve, showing the page's site, and the item's note says where it came from. Saving over an
existing item keeps the old value in its history. After a save, the panel shows the reference to use, ready to copy.

Spotting happens in the page: nothing leaves it until you press Save, and then the value goes only to the app.

Turn it on in Safari › Settings › Extensions; Safari asks you to allow it on each site, or on all of them. Its toolbar
button says whether it can reach Latchkey and lists what it found on the page. If Latchkey isn't listed
there with a development build, turn on Safari › Settings › Advanced › **Show features for web developers**, then
Develop › **Allow Unsigned Extensions**; a notarized release doesn't need this.

The extension can't read any stored value, not even an agent-safe one. It reaches the app through its own socket, which
admits only Latchkey's signed extension and only for listing item names and saving a value.

