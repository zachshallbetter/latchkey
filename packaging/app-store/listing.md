# App Store listing

What goes into App Store Connect for the first Mac App Store version (free, no in-app purchase). Claims follow
`docs/`. Apple's limits: name and subtitle 30 characters, promotional text 170, description 4000, keywords 100 bytes,
review notes 4000 bytes; `scripts/appstore-preflight.py` checks them.

## App information

- **Name:** Latchkey: Dev Secrets
  ("Latchkey" alone was taken on the store; the app itself is still called Latchkey.)
- **Subtitle:** Secrets for Macs and AI agents
- **Bundle ID:** io.snackstud.latchkey (extension io.snackstud.latchkey.safari). **SKU:** latchkey-mac
- **Primary category:** Developer Tools. **Secondary:** Productivity
- **Primary language:** English (U.S.)
- **Content rights:** the app contains no third-party content that needs rights.
- **Copyright:** 2026 Snack Studio
- **Support URL:** https://latchkey.snackstud.io/support.html
- **Marketing URL:** https://latchkey.snackstud.io/
- **Privacy policy URL:** https://latchkey.snackstud.io/privacy.html
- **Price:** Free in all 175 countries and regions. No in-app purchases in this version. Released manually after approval.

## Promotional text

Keep API keys out of your project files. Latchkey fills them in when a command starts and asks you, with Touch ID, before a program or agent gets a value.

## Description

Your project files keep references like latchkey://shop/production/DATABASE_URL. Latchkey keeps the values in iCloud Keychain and fills them in when a command starts, so .env files stop holding secrets, values follow you to every Mac you use, and an agent only gets what you've allowed.

KEEPS VALUES OUT OF FILES
Import a .env file, or a hundred, and Latchkey places each value for you and can replace it in the file with a reference. Settings and public values are recognized and left alone; anything unclear is treated as a secret. Export an environment back to an env file or copy it as a .env block, each time after you approve it.

ASKS BEFORE IT SHARES
Reading an item asks you (Touch ID, Apple Watch or your Mac password) and shows which program is asking, from which folder, for which command. Allow once, allow a folder for a while, or mark an item safe for agents to read.

ORGANIZED BY PROJECT
Items belong to a project's environment (shop/development, shop/production) or are shared. Search, filter by service, move items between environments, and review findings such as the same key stored twice.

PUSHES TO YOUR PLATFORMS
Send an environment's variables to Vercel, Railway or Fly with an access token you keep in Latchkey. Every push asks first, and production needs an extra confirmation.

REMEMBERS
Every read and change is logged without values. Earlier values are kept, and a deleted item can be restored for 30 days.

SYNCS
Values are stored in iCloud Keychain, end-to-end encrypted, on every Mac signed in to your Apple Account. Latchkey has no server of its own and collects no data.

LATCHKEY FOR SAFARI
When a page shows you a new API key, the Safari extension offers to save it to Latchkey, and can fill a saved key into the site it belongs to. Each save and each fill asks you first. Turn it on in Safari Settings > Extensions.

FOR THE COMMAND LINE AND CODING AGENTS
The free Latchkey command-line tool, a separate download from latchkey.snackstud.io, runs your commands with values filled in and works with coding agents, which never hold the values. You choose what each one can use, and every value it asks for is approved in this app.

Requires macOS 15 or later. iCloud Keychain must be on to sync between Macs.

## Keywords

secrets,api key,env,dotenv,keychain,developer,token,credentials,agent,vault,password,safari

## What's New

Not shown for a first version.

## Screenshots

`packaging/app-store/screenshots/` holds six 2880 × 1800 JPEGs (no transparency) made from the app's own views with
example data (`scripts/compose-screenshot.swift`; see docs/app-store.md). Upload them in order; they show fictional
projects and values only.

## App Review information

- **Sign-in required:** No.
- **Contact:** Owner fills in name, phone (+ international format) and email (latchkey@snackstud.io) in App Store
  Connect.
- **Notes:**

Latchkey needs no account, sign-in or developer environment to review. Everything is stored on the Mac and in iCloud Keychain; there is no server.

To exercise the app:
1. Open Latchkey and choose New Item. Enter a name such as demo/development/API_KEY and any test value, and save. Approve the macOS prompt (Touch ID or the Mac's password).
2. Choose File > Import .env File and pick a text file with lines like API_KEY=test123. The sheet classes each line; save to import.
3. Control-click a project in the sidebar and choose Export Environment or Copy Environment as .env. Files are written only where you choose in the system file picker.
4. Review lists findings such as duplicates; Activity logs every read and change (never values); Recently Deleted restores items.
5. Safari: enable Latchkey in Safari Settings > Extensions. On any page, select text, Control-click and choose Save Selection to Latchkey; the app asks before saving.
6. Settings (Command-comma) has every option; the Help menu opens support, privacy policy and terms.

Approvals use the standard macOS authentication sheet, which accepts Touch ID, Apple Watch or the login password, so a Mac without Touch ID works. An unanswered prompt is a denial after 90 seconds.

Safari extension access: its content script runs on all sites because API keys are shown on many dashboards. It looks for key-shaped text in the page locally and sends nothing anywhere until the person clicks Save; fills happen only on the item's own service site and deployment dashboards, after approval.

Command-line tool: optional and separate (free download, latchkey.snackstud.io/cli.html, signed with the same team's Developer ID). The app never installs or launches it. It connects over a Unix socket in the app's App Group container, which checks the tool's code signature, and every value it asks for is approved in the app. The key proxy and AWS session features run in that tool, not in the app.

Background behavior: launching at login is off unless the person turns it on in Settings. Closing the window leaves Latchkey in the menu bar; Quit (menu bar or app menu) quits it, and quitting from the Dock quits unless the person chose otherwise in Settings.

Network: only requests the person asks for, to the provider APIs they link (Vercel, Railway, Fly). No analytics, advertising or tracking.

## App Privacy

- **Data collection:** "No, we do not collect data from this app." Nothing is sent to Snack Studio or any party it
  chooses; values sync through the person's own iCloud Keychain, and pushes go to providers the person links with
  their own token.
- **Tracking:** none.

## Age rating

Answer **None / No** to every question (no mature themes, no user-generated content shared with others, no web
browsing, no social features, no chance-based activities). Expected rating: 4+.

## Export compliance

`ITSAppUsesNonExemptEncryption` is NO in the store build: it uses only Apple's encryption (Keychain, HTTPS). The
sealed box GitHub's API requires (X25519 and XSalsa20-Poly1305) is in the `LatchkeySeal` library, which the store
build doesn't link, so this version has no GitHub pushes. App Store Connect asks no export questions and needs no
documents. This is not legal advice.

## EU Digital Services Act

Snack Studio declares trader status in App Store Connect (Business > Agreements > Compliance); its address, phone and
email then appear on the EU product page.
