# Agent guidelines — sonus-auris-web-desktop.dart

Flutter console for viewing and controlling Sonus Auris devices across web, Linux, macOS, and Windows.

## Instruction discovery

- Resolve the real path of `$PWD`, walk its ancestor directories through the filesystem root, and load every readable lowercase `agents.md` in root-to-leaf order.
- Do not search sibling directories. Deduplicate canonical paths, detect symlink cycles, and report unreadable instruction files.
- `AGENTS.md`, `.claude/CLAUDE.md`, `.gemini/GEMINI.md`, and `.openai/AGENTS.md` are compatibility pointers only; lowercase `agents.md` files are canonical.

## Linear mapping

- GitHub organization: `github.com/sonus-auris`.
- Linear project: `github.com/sonus-auris` in the Denman workspace.
- Locate or create the matching Linear issue before substantial work. Record PR links, Flutter/browser/platform test evidence, blockers, and remaining work there.

## Console, auth, and platform invariants

- Keep the web and desktop surfaces behaviorally aligned where platform capability permits; document intentional platform differences.
- Preserve passwordless Supabase sign-in, explicit account/session states, secure token storage, account deletion, consent, and device-management semantics.
- Never place service-role, object-store, database, signing, or backend credentials into Flutter builds. Public client configuration is not authorization.
- Treat the production Flutter web build as a browser-delivered application: preserve branded title/PWA metadata, correct base-href and asset routing, no fatal boot errors, and no failed critical assets.
- Keep authenticated data private and avoid logging tokens, cookies, credentials, recording keys, raw audio, or sensitive user content.
- Device-control actions must remain explicit, authenticated, bounded, and reflected in UI state; do not silently treat optimistic state as confirmed server state.
- Release and installer publication must remain in protected workflows. Generated web bundles, native binaries, and installer artifacts do not belong in source control.

## Command and Git safety

- Do not use raw recursive deletion, mass restore, hard reset, clean, force-push, or history-rewriting synchronization.
- Preserve uncommitted and unmerged work. Prefer `git rm`, `git mv`, single-path restoration, normal commits, and reversible operations.
- Start from current `main`, use a focused branch and PR, and avoid git rebase in favor of git merge.
- “Sync with remote” means inventory branches/worktrees, preserve valid work, run `git fetch --all --prune`, merge upstream, test, push, and verify local and remote `main` contain the intended commits.
- Resolve conflicts semantically: do not merely choose ours or theirs. Merge the intended Flutter, auth, device, web, and desktop behavior conceptually.
- Grep for `<<<<<<<`, `=======`, and `>>>>>>>`; repeat review and testing until no conflict markers remain.

## Validation

Run Flutter formatting, analysis, unit/widget tests, production web builds, Puppeteer/Playwright boot smokes against the generated build, platform desktop builds where affected, PWA/base-href/asset checks, auth/session tests, and dependency/release-tooling checks before merge.
