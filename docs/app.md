# The app

Latchkey is a regular Mac app with a window and a menu bar icon. It also answers the command-line tool, so it needs
to be running for `latchkey run` to work (the tool starts it if it isn't). Only one copy runs at a time.

## The window

### Sidebar

Arranged the way 1Password arranges vaults and tags:

- **All Items**, **Review** (with how many findings) and **Activity**.
- **Projects** (and **Shared**), like vaults: choose one to see only its items. Right-click for actions on all of
  them.
- **Services**, like tags: the services items name.
- **Grants** and **Recently Deleted**.
- Projects and Services fold away.
- At the bottom, where values are kept: **iCloud Keychain** or **This Mac only**. Hover for what that means.

### The list

The list's header names what's shown and how many (items, projects and services), with a **New Item** button and a
search field (⌘F). Under the search field, **Type**, **Environment**, **Project** and **Service** dropdowns narrow the
list and show what they're set to, and the button after them holds the sort order, access, **Clear Filters**,
**Import .env File…** and **Move Selected to a Project…**. Items are listed by name in two lines: an icon for its type
(token, API key, database, URL, password, key file, plain value; hover for its name) beside the name, and under it its
project, environment and service. Long names are shortened in the middle, with
the full ID on hover, and hovering a row shows a button that copies its `latchkey://` reference.

Badges on an item: a green shield for agent-safe, an orange arrow when its value changed since it was last pushed to a
remote location, a crossed-out cloud when it hasn't been pushed there yet.

Right-click a project in the sidebar to act on all its items: select all, require approval or let agents read, grant
access, move, delete. An environment's **Remote Locations…** opens from the Remote card of any of its items.

### Review, Activity, Recently Deleted and Grants

Each is a list with the selected entry's detail on the right.

- **Review** lists findings, filtered by **Access**, **Duplicates**, **Changes**, **Environment** or **Grants**: items
  any program can read without approval, values changed since a push or not pushed yet, environment variables
  `lk env migrate` found that nobody has confirmed, and grants ending within a day. A finding's detail lists what it's
  about and the recommended action (**Require Approval…**, **Push…**, **Confirm All…**).
- **Find Duplicates…** (Review) compares every secret's value inside Latchkey, with one Touch ID, and adds a finding
  for each group holding the same key, with the same advice as `lk duplicates`. A production key used elsewhere is
  flagged to be replaced; several names for one value in one environment offer **Keep One Item…**; identifiers saved
  as secrets offer **Mark as Plain Values…**; the rest offer **Combine into Shared…**, which names the shared item.
  Environments and the files they were imported from follow, and the originals go to Recently Deleted. Groups are kept in memory until the
  app quits; no value is shown.
- **Activity** has search and filters by event and project, grouped by day. An entry's detail shows the action, the
  items, the decision, who asked through which programs, the folder and the command. Values are never logged.
- **Recently Deleted** has search; an item's detail shows when and by whom it was deleted, its ID, service and last
  value (shown only with approval), with **Restore Item** and **Permanently Delete…**.
- **Grants** is a table of item, folder, limits, status and end; a grant's detail has **Revoke Grant** and **Show
  Folder**.

### Selecting several items

⌘-click or ⇧-click to select several, ⇧↑ and ⇧↓ to extend the selection, and ⌘A to select every row shown. The
detail pane becomes a summary with actions for all of them: copy their references, require approval or let agents
read, set the kind or service, move, grant access, delete. Each change asks for Touch ID once.

The **Item** menu and the right-click menu act on the selected rows that are shown, with these shortcuts while the list
has focus:

| Action | Shortcut |
| --- | --- |
| Copy Value (one item) | ⌥⌘C |
| Copy Reference, or every selected item's reference, one per line | ⇧⌘C |
| Copy as Env File Lines (`NAME=latchkey://ID`) | ⇧⌘E |
| Require Approval, or Let Agents Read Without Asking | ⌥⌘A |
| Move to a Project… | ⇧⌘M |
| Grant Access… | ⇧⌘G |
| Delete… | ⌘⌫ or Delete |

Deleting always asks first. Kind has no shortcut; it's in both menus.

### An item's detail

- **Value**: hidden. The eye shows it for 30 seconds (Settings › Privacy & Approval changes this); the copy button
  copies it to this Mac's clipboard only (not to your other devices through Universal Clipboard), marks it so clipboard
  managers skip it, and clears it after the chosen delay, 60 seconds unless changed. Both ask unless the item is
  agent-safe.
- **Reference**: the `latchkey://` text to paste into a file.
- The header shows the item's project, environment and service. **Edit** offers **Change Value…**, **Edit
  Details…** (kind, access, service, note and Safari fill sites, saved together with one Touch ID), **Move…**,
  **Remote Locations…**, **Export Environment…**, **Copy Environment as .env…**, **Copy Reference** and **Delete…**
  (the item moves to Recently Deleted for 30 days).
- **Type** (hover for how it's stored and whether it's masked), **Access** (switch it to let any program read it
  without approval), **Service** (with a link to make a new key there), **Project**, **Environment**, **Note**, and
  **Location**: the files it was imported from; click to list them.
- Grants that cover it, with **Revoke**.
- **Remote**, when its environment is linked: where the item stands; click to manage the locations.
- **Recent Activity**, then **History**: click for earlier values, with show and restore; **Forget History…** deletes
  them for good.

### Exporting an environment

**Export Environment…** (in an item's **Edit** menu, and under **Export Environment** in a project's right-click menu)
writes the environment's env file from its record, as `lk export` does and with the same checks. Choose references or
values and a file. If the file exists, **Merge** updates the variables Latchkey manages, adds the missing ones and
keeps everything else in the file as it is, listing the names it adds and updates before you press **Merge**;
**Replace the file** rewrites it. Values are written in plain text, readable only by you, after an approval that
names the file; the sheet refuses a file Git tracks or doesn't ignore, and warns about a folder that syncs to a cloud
service.

**Copy Environment as .env…** puts the environment on the clipboard as an env block for a dashboard that takes a pasted
one (Vercel, Railway, Netlify, Render). It asks every time, naming the environment and that the values go to the
clipboard, and when it clears. The copy stays on this Mac, is marked so clipboard managers skip it, and clears after
the chosen delay (60 seconds unless changed) if nothing else is copied. The access log says "copied to the clipboard", never the values. Agents can't do this.

### Adding and importing

- **New Item** in the list's header, or **File › New Item…** (⌘N).
- **File › Import .env File…** (⇧⌘I), or drop a file on the window. The sheet proposes the project and environment,
  lists each key with its kind and agent-safe setting, marks keys that already exist, and lists lines it leaves alone
  (empty, already references, or expiring Vercel and Turbo tokens). Import asks once. **Replace values in the file
  with latchkey:// references** rewrites the file afterwards.

### Moving

**Move to a Project…** (item menu, **Edit › Move…**, or the list's **…** menu): pick items, a project and environment (or Shared), and the
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

One prompt at a time:

- **Changes** (add, change, delete, import, move, restore, link) ask with the macOS Touch ID sheet alone, which says
  what, who and where: "Latchkey is trying to add shop/development/DB, asked by Claude in ~/Projects/shop." Its
  **Details…** button opens the panel with everything (the items, the agent and the programs it runs through, the
  folder and the command), where **Allow** asks for Touch ID again and **Deny** refuses.
- **Releasing values to a command** shows the panel first, titled like "Claude wants to use 2 items". Choose
  **Allow Once**, or tick **Allow from this folder** (for a time, until the agent quits, or only for this command);
  Touch ID or your password confirms. So do earlier values, grants asked for ahead of time and pushes, where
  production needs **I mean to change production** ticked first.
- A request from another computer over SSH, or from a program that isn't Latchkey's command-line tool, always shows
  the panel first, with its warning.
- A sheet or panel nobody answers is a denial after 90 seconds. Things you start yourself, in the window or in
  Latchkey for Safari, ask for Touch ID alone.
See [Concepts](concepts.md#approvals).

After an import or a new item, Latchkey shows what to do next: the reference to put in your env file and the
`lk run` command for that folder, ready to copy.

## The menu bar

Click the key: search your items, copy a value, open an item in the window, open Settings, or quit.

**Latchkey › Check for Updates…** (direct download only; the App Store updates it) looks for a newer version now.

Closing the window, or Quit from the Dock, leaves Latchkey in the menu bar without a Dock icon, so the command-line
tool and agents keep working; **Open Latchkey** brings the window and the Dock icon back. To quit for real, use **Quit** in the menu bar
or **Latchkey › Quit Latchkey**.

## The Help menu

**Help** has **Latchkey Help** (the support page), **Privacy Policy**, **Terms of Use** and **Report a Security
Issue**, which opens a message to latchkey@snackstud.io with the subject "Security". The first three open
latchkey.snackstud.io in your browser.

## Settings

Settings is part of the main window: choose **Settings** in the sidebar, press **⌘,**, or use the app or menu bar
Settings command. The same destination opens each time, including when the window was closed. Sections are:

- **General**: follow macOS appearance or choose Light/Dark, open at login, and choose whether quitting from the
  Dock keeps Latchkey running in the menu bar. Quit from the Latchkey menu always exits.
- **Privacy & Approval**: clear copied values after 15, 30, 60 or 120 seconds; hide revealed values after 10, 30 or
  60 seconds; hide revealed values when the app loses focus; or hide them immediately. Timer changes apply on
  the next copy or reveal. Closing the window also hides values. Clipboard clearing preserves anything copied
  afterward; values stay on this Mac and retain the clipboard-manager concealment markers. This section also
  explains approval and links to active grants. No preference bypasses authorization.
- **Storage & File Access**: Keychain location, legacy-item migration, and remembered file/folder permissions in
  the App Store build. File permission and secret-release approval remain separate. macOS may retain access to
  an opened file for the rest of the process even after its bookmark is removed.
- **Developer Tools**: install the bundled CLI in the direct build, setup help, activity, and the access log.
- **Membership**: the current plan, one-time Pro ownership and purchase date, localized App Store pricing,
  availability checks, purchase and restore actions, and purchase support/policy links. The direct build identifies
  itself and links to the plans page; it does not claim to verify App Store purchases. Pro is a non-consumable
  purchase, with no recurring subscription or renewal. All current features remain free; planned additions are
  described as planned. No purchase state is stored as an editable preference.
- **About & Updates**: app version, distribution, direct-build automatic updates and manual update checks, help,
  privacy policy, terms and security reporting. The App Store build gets updates through the App Store.

Preferences are saved on this Mac. Clipboard clearing defaults to 60 seconds, revealed values to 30 seconds,
hiding on loss of focus to on, and keeping the app running after a Dock quit to on.

## Latchkey for Safari

Latchkey comes with a Safari extension that spots a new key on the page where you made it and saves it when you say
so. It recognizes the formats of about twenty providers (Stripe, OpenAI, Anthropic, GitHub, GitLab, Slack, Google,
npm, Hugging Face and others), private keys, database URLs with a password, and long random values labelled as a
secret or token. It skips what isn't secret or isn't a real key: masked values, examples, publishable keys, commit
hashes. Certificates are public, so they're never marked on the page; the toolbar panel lists them, and saving one
makes a plain (unmasked) item.

- When a page shows a new key and says it won't show it again, the save panel opens from its button on its own, once;
  press **Save to Latchkey** (or Return) to save it, or **Not now**.
- For stronger matches, a **Save to Latchkey** button sits on the box that holds the key: inside a one-line field at
  its right end, or on the top edge of a larger box. The panel opens from it, beside the box rather than over the
  key. Press it, choose where it goes (shared, or a
  project's environment; a live or test key is matched to production or development when it can be) and its name,
  then **Save to Latchkey**.
- Less certain finds aren't marked on the page: the toolbar button shows how many it spotted, and its panel lists them
  (a short preview, never the value) so you can open the save panel for one.
- For anything it missed, select the text, Control-click, and choose **Save Selection to Latchkey**.
- It also notes fields that expect a key, token, secret, private key, certificate or connection string, the way a
  password manager spots password fields: by label, placeholder, name and autocomplete hint, never by what's in them.
  Sign-in passwords, one-time codes and email fields aren't counted. The toolbar panel lists them.
- **Fill from Latchkey:** click into one of those fields and a Latchkey badge appears in it. The badge lists the items
  that may be filled on this site, most like the field first; choose one and approve with Touch ID, and the value goes
  into that field. An item may be filled only on its service's own site (a Stripe key on stripe.com) and on the sites
  where deployments keep environment variables and secrets: Vercel, GitHub, Railway, Fly, Netlify, Render, Cloudflare,
  Supabase, Heroku, and the AWS and Google Cloud consoles. To choose instead, set **Fill in Safari on** in the item's
  details (host names separated by commas, each covering its subdomains): the item is then filled only on those
  sites. Leave it empty for the default. The app decides this, over https only, and asks every time; no grant or
  agent-safe setting stands in. Fill never reaches a frame inside the page.

The app asks you to approve, showing the page's site, and the item's note says where it came from. Saving over an
existing item keeps the old value in its history. After a save, the panel shows the reference to use, ready to copy.

Spotting happens in the page: nothing leaves it until you press Save, and then the value goes only to the app.

Turn it on in Safari › Settings › Extensions; Safari asks you to allow it on each site, or on all of them. Its toolbar
button says whether it can reach Latchkey and lists what it found on the page. If Latchkey isn't listed
there with a development build, turn on Safari › Settings › Advanced › **Show features for web developers**, then
Develop › **Allow Unsigned Extensions**; a notarized release doesn't need this.

The extension can't read stored values; the one exception is fill, which releases one item into the field you chose
after you approve it. It reaches the app through its own socket, which admits only Latchkey's signed extension and only
for listing item names, saving a value and filling one item.

