# App Store listing drafts

Drafts for App Store Connect. Nothing here is uploaded or final; the owner reviews every field. Claims follow
`docs/`; where a decision is still open it is marked **Owner**. Limits are Apple's: subtitle 30, promotional text
170, description 4000, keywords 100 characters.

## Name

Latchkey

## Subtitle

Secrets for Macs and AI agents

## Promotional text

Keep API keys out of your project files. Latchkey fills them in when a command starts and asks you, with Touch ID, before a program or agent gets a value.

## Description

Your project files keep references like latchkey://shop/production/DATABASE_URL. Latchkey keeps the values in iCloud Keychain and fills them in when a command starts, so .env files stop holding secrets, values follow you to every Mac you use, and an agent only gets what you've allowed.

KEEPS VALUES OUT OF FILES
Import a .env file, or a hundred, and Latchkey places each value for you and can replace it in the file with a reference. Settings and public values are recognized and left alone; anything unclear is treated as a secret. Export an environment back to an env file or copy it as a .env block, each time after you approve it.

ASKS BEFORE IT SHARES
Reading an item asks you (Touch ID, Apple Watch or your Mac password) and shows which program is asking, from which folder, for which command. Allow once, allow a folder for a while, or mark an item safe for agents to read. Pushing to production needs an explicit confirmation.

ORGANIZED BY PROJECT
Items belong to a project's environment (shop/development, shop/production) or are shared. Search, filter by service, move items between environments, and review findings such as the same key stored twice.

REMEMBERS
Every read and change is logged without values. Earlier values are kept, and a deleted item can be restored for 30 days.

SYNCS
Values are stored in iCloud Keychain, end-to-end encrypted, on every Mac signed in to your Apple Account. Latchkey has no server of its own and collects no analytics.

LATCHKEY FOR SAFARI
When a page shows you a new API key, the Safari extension offers to save it to Latchkey, and can fill a saved key into the site it belongs to. Each save and each fill asks you first. Turn it on in Safari Settings > Extensions.

FOR CODING AGENTS
Agents run commands through Latchkey's command-line tool and never hold the values. You choose what each agent can use, and Latchkey hides values if a command prints them.

FREE TO USE, PRO PLANNED
Everything above is free. Latchkey Pro, planned as a one-time in-app purchase with no subscription, will add features for individual power users.

Requires macOS 15 or later. iCloud Keychain must be on to sync between Macs.

## Open items

**Owner:** the command-line tool is a separate download (see reviewer notes). Add a line to the description naming where to get it once that is decided, and re-check the agent paragraph against the final store feature set before submitting; the full-functionality gates in readiness.json are still pending.

## Keywords

secrets,api key,env,dotenv,keychain,developer,token,credentials,agent,vault,password,safari

## What's new

First release on the Mac App Store: store and organize API keys by project, import and export .env files, approve each use with Touch ID, sync through iCloud Keychain, and save keys from Safari.

## Reviewer notes

Latchkey needs no account, sign-in or developer environment to review. It stores everything on the Mac and in the reviewer's iCloud Keychain; there is no server.

To exercise the app:
1. Open Latchkey. In the window choose New Item, enter a name such as demo/development/API_KEY and any test value, and save. Approve the macOS prompt.
2. Choose Import .env File and pick any text file containing lines like `API_KEY=test123`. The import sheet lists each line with its class; save to import.
3. Choose Export Environment to write an env file of references, or Copy Environment as .env to the clipboard. Choose a file in the system file picker; the app only touches files you select.
4. Open Activity to see the log of every read and change (no values) and Recently Deleted to restore a deleted item.
5. Safari: turn on Latchkey in Safari Settings > Extensions, open any page, select text, Control-click and choose Save Selection to Latchkey. The app asks before saving.
6. The Help menu opens the support page, privacy policy, terms and a security contact.

Approval without Touch ID: every approval uses the standard macOS authentication sheet, which accepts Touch ID, Apple Watch or the Mac's login password. A Mac without Touch ID hardware, or a clean test Mac, can approve with the password. An unanswered prompt is treated as a denial after 90 seconds.

Command-line tool: Latchkey also has a command-line tool (`latchkey`, `lk`) that runs a developer command with values filled in. It is a separate, separately code-signed product, not embedded in or installed by the app, and it talks to the app over a local socket in the shared App Group container that checks the tool's signing identity. The app is fully reviewable without it. **Owner:** state here where reviewers can download it, and confirm the sandboxed app serves it as described in docs/app-store.md.

Network use: only requests the user asks for (provider calls for remote pushes and the key proxy). No analytics, advertising or tracking.

Contact: latchkey@snackstud.io. **Owner:** add the review contact name and phone in App Store Connect and set reviewContactConfirmed after checking.
