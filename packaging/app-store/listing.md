# App Store listing

What goes into App Store Connect for the first Mac App Store version (free, no in-app purchase). Claims follow
`docs/`. Apple's limits: name and subtitle 30 characters, promotional text 170, description 4000, keywords 100 bytes,
review notes 4000 bytes; `scripts/appstore-preflight.py` checks them.

## App information

- **Name:** Pistachio: Secrets in a Shell
  (the app itself is called Pistachio.)
- **Subtitle:** Less copying. More building.
- **Bundle ID:** io.snackstud.latchkey (extension io.snackstud.latchkey.safari). **SKU:** latchkey-mac (set when the record was created; App Store Connect can't change it)
- **Primary category:** Developer Tools. **Secondary:** Productivity
- **Primary language:** English (U.S.)
- **Content rights:** the app contains no third-party content that needs rights.
- **Copyright:** 2026 Snack Studio
- **Support URL:** https://secretsinashell.com/support.html
- **Marketing URL:** https://secretsinashell.com/
- **Privacy policy URL:** https://secretsinashell.com/privacy.html
- **Price:** Free in all 175 countries and regions. No in-app purchases in this version. Released manually after approval.

## Promotional text

Your secrets. In a shell. API keys live in iCloud Keychain, not your .env files, and nothing uses one until you approve it with Touch ID.

## Description

Your secrets. In a shell.

Pistachio keeps API keys in iCloud Keychain and out of your .env files. Your files hold references. Pistachio holds the values, and asks you before anything uses one.

IMPORT ONCE
Import a .env file. Secrets move to Keychain; settings stay put. The file keeps a reference in place of each value.

APPROVE WITH TOUCH ID
See which agent is asking, from which folder, for which keys. Allow once or deny.

GRANT A FOLDER TIME
Let one project read the keys you pick for a set time, like two hours. Then it asks again.

SEE WHAT WAS USED
Activity lists every request and every key released. Never the value.

ROTATE WITHOUT EDITING FILES
Change a key and every reference keeps working. Old values stay in History.

SAVE FROM SAFARI
A new key on a dashboard? Save it to Pistachio before you close the tab.

PRIVATE AND FREE
End-to-end encrypted in iCloud Keychain, synced to your Macs. No account, no server, no subscription, no data collected.

Works with the free Pistachio command-line tool and coding agents (separate download at secretsinashell.com). Requires macOS 15 or later.

## Keywords

secrets,api key,env,dotenv,keychain,developer,token,credentials,agent,vault,password,safari

## What's New

Not shown for a first version.

## Screenshots

`packaging/app-store/screenshots/` holds ten 2880 × 1800 JPEGs (no transparency) made from the app's own views with
example data and composed with a caption (`scripts/compose-screenshot.swift`; see docs/app-store.md). Upload them in
order; they show fictional projects and values only.

| File | Caption | Subtitle |
| --- | --- | --- |
| 01-items | Secrets, sorted by project. | References in your files. Values in iCloud Keychain. |
| 02-approval | Nothing shared without asking. | Touch ID shows which program wants which value, and why. |
| 03-import | Import a .env in seconds. | Each line is sorted: secrets kept, settings left alone. |
| 04-project | Every environment in one place. | Development, preview and production, side by side. |
| 05-review | Catches duplicates and strays. | Review finds the same key stored twice, and more. |
| 06-activity | Know what read what. | Every read and change is logged. Never the value. |
| 07-push | Push to your platforms. | Send variables to Vercel, Railway or Fly, with a second check for production. |
| 08-menubar | Always a click away. | Requests and items, right in the menu bar. |
| 09-appearance | Make it yours. | The pistachio or the key, in the palette you like. |
| 10-lock | Locks when you step away. | Touch ID or your password opens it again. |

## App Review information

- **Sign-in required:** No.
- **Contact:** Owner fills in name, phone (+ international format) and email (latchkey@snackstud.io) in App Store
  Connect.
- **Notes:**

Pistachio needs no account, sign-in or developer environment to review. Everything is stored on the Mac and in iCloud Keychain; there is no server.

To exercise the app:
1. Open Pistachio and choose New Item. Enter a name such as demo/development/API_KEY and any test value, and save. Approve the macOS prompt (Touch ID or the Mac's password).
2. Choose File > Import .env File and pick a text file with lines like API_KEY=test123. Each line gets an action, Save to Keychain or Keep in file, and the sheet previews the file after import; choose Import.
3. Control-click a project in the sidebar and choose Export Environment or Copy Environment as .env. Files are written only where you choose in the system file picker.
4. Review lists findings such as duplicates; Activity logs every read and change (never values); Recently Deleted restores items.
5. Safari: enable Pistachio for Safari in Safari Settings > Extensions. On any page, select text, Control-click and choose Save Selection to Pistachio; the app asks before saving.
6. Settings (Command-comma) has every option; the Help menu opens support, privacy policy and terms.

Approvals use the standard macOS authentication sheet, which accepts Touch ID, Apple Watch or the login password, so a Mac without Touch ID works. An unanswered prompt is a denial after 90 seconds.

Safari extension access: its content script runs on all sites because API keys are shown on many dashboards. It looks for key-shaped text in the page locally and sends nothing anywhere until the person clicks Save; fills happen only on the item's own service site and deployment dashboards, after approval.

Command-line tool: optional and separate (free download, secretsinashell.com/cli.html, signed with the same team's Developer ID). The app never installs or launches it. It connects over a Unix socket in the app's App Group container, which checks the tool's code signature, and every value it asks for is approved in the app. The key proxy and AWS session features run in that tool, not in the app.

Background behavior: launching at login is off unless the person turns it on in Settings. Closing the window leaves Pistachio in the menu bar; Quit (menu bar or app menu) quits it, and quitting from the Dock quits unless the person chose otherwise in Settings.

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
