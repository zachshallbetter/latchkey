## What and why

<!-- What does this change do, and what problem does it solve? -->

## How it was verified

<!-- Tick what you ran. CI runs `swift test` on pull requests that touch the package. -->

- [ ] `swift test` green
- [ ] `node --test App/Safari/*.test.js` green (Safari extension changes)
- [ ] App builds and the behavior was checked (app changes; not covered by CI)
- [ ] No stored value reaches a log, error, test output or command argument

## Notes

<!-- Anything reviewers should know: trade-offs, follow-ups, screenshots. -->
<!-- Update the Unreleased section of CHANGELOG.md for a user-visible change. -->
