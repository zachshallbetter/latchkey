# Security policy

## Reporting a vulnerability

Report it privately through GitHub: the repository's **Security** tab › **Report a vulnerability**. Please don't
open a public issue, pull request or discussion for it.

Include what you can of:

- the Latchkey version (`latchkey status`, or **Latchkey › About Latchkey**) and macOS version;
- what an attacker can do, and what they need first (a process running as you, another user on the Mac, an
  approved agent, a pushed link);
- steps to reproduce, with example values only. Never send a real secret.

You'll get a reply in the advisory. Once a fix ships, the advisory is published and credits you unless you'd rather
it didn't.

## In scope

- Releasing a value without an approval, a grant covering the caller, or the item being agent-safe.
- A grant reaching folders, repositories, items or times it doesn't name.
- The approval panel showing a folder or command other than the caller's.
- Values in logs, errors, the access log, the activity list, version metadata or command-line output other than
  `latchkey get`.
- Pushing to a remote location without approval, or to production without the extra confirmation.
- Another user on the Mac reaching the broker socket or Latchkey's files.
- Items readable outside Latchkey's keychain access group.

## Out of scope

The limits in [docs/security.md](docs/security.md#where-protection-ends), including:

- any process running as you asking the broker, and agent-safe items or grants releasing to it from the right
  folder;
- the names of a caller's parent processes being faked (the caller itself is checked by signature);
- a command you approved, or one a grant covers, doing what it likes with the values it was given;
- masking missing anything but an exact copy, 6 characters or longer, of a released value;
- `latchkey get` printing the value it was asked for;
- old values kept in history until they're forgotten or expire;
- someone who controls your Apple Account and a trusted device;
- unsigned development builds, which use the login keychain.

## Supported versions

Fixes go into the latest release. Update to it before reporting.
