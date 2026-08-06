# Agent guidelines — sonus-auris-ui.dart

Dart/Flutter client — always-on rolling-window audio recorder (a dashcam for audio).

## Instruction discovery

- Resolve the real path of `$PWD`, walk its ancestors through the filesystem root, and load every readable lowercase `agents.md` in root-to-leaf order.
- Do not search sibling directories. Deduplicate canonical paths, detect symlink cycles, and report unreadable instruction files.
- `AGENTS.md`, `.claude/CLAUDE.md`, `.gemini/GEMINI.md`, and `.openai/AGENTS.md` are compatibility pointers only; lowercase `agents.md` files are canonical.

## Linear mapping

- GitHub organization: `github.com/sonus-auris`.
- Linear project: `github.com/sonus-auris` in the Denman workspace.
- Locate or create the matching Linear issue before substantial work, and record PR links, tests, blockers, and remaining work there.

## Desktop implementation parity

- Sonus Auris actively maintains two desktop applications: this repository's Flutter desktop entrypoint and `sonus-auris/desktop.app.rs` in Rust.
- Implement user-facing desktop features, privacy controls, lifecycle behavior, and bug fixes in both desktop applications unless a tracked design decision explicitly marks a capability as platform-specific or intentionally deferred.
- Keep behavior, terminology, defaults, retention limits, consent text, authentication requirements, cloud contracts, and release expectations aligned across the Rust and Flutter desktop implementations.
- When a change lands in only one desktop repository, create or update the paired Linear issue and document the remaining parity work in the PR.
- Shared protocol/schema behavior belongs in the existing Sonus Auris interface or backend contracts; do not create a third UI-components repository merely to share widgets between Rust and Flutter.

## Flutter and privacy invariants

- The default local plaintext rolling-audio retention ceiling is 100 hours. Do not increase it, silently make it unlimited, or bypass expiration enforcement.
- Preserve on-device encryption before upload and platform secure storage for keys/tokens. Never log credentials, authorization headers, recording keys, or raw audio.
- Supabase public client configuration may be embedded as intended; service-role and backend/object-store secrets must never enter Flutter builds.
- Keep passwordless authentication, account deletion, consent, recording indicators, permissions, and user-controlled location/analysis/backup behavior testable and explicit.
- Store publication must remain gated through protected workflows and signing credentials. Never publish, sign, notarize, or upload without the configured protected environment and explicit release inputs.
- Generated installers and mobile artifacts belong in CI/release storage, not the repository.
- Run Flutter formatting/analyze/tests, platform compilation, emulator/permission integration, release-tooling validation, and applicable desktop/mobile build checks before merge.

## Command safety — STRICT

Never run destructive or irreversible shell commands. Remove or move tracked files through git so changes remain recoverable.

- Do not use raw `rm`, recursive deletion, raw `mv` of tracked files, mass truncation, `git reset --hard`, `git clean -fdx`, mass restore, stash destruction, forced ref deletion, or force-pushes.
- Prefer `git rm`, `git mv`, single-path `git restore`, `git revert`, normal `git stash`, focused edits, commits, and feature branches.
- Stop and ask the operator before any genuinely destructive or binding action.

## Syncing with the remote

1. Inventory local branches, worktrees, uncommitted changes, and relevant remote refs. Preserve all valid work.
2. Commit or safely stash intended work before integrating incoming changes.
3. Run `git fetch --all --prune`.
4. Integrate upstream with merge-based history; do not rebase shared work.
5. Resolve conflicts semantically: do not merely choose ours or theirs. Merge the intended behaviors conceptually.
6. Grep for `<<<<<<<`, `=======`, and `>>>>>>>`; repeat review and tests until no conflict markers remain.
7. Run the complete Flutter and release-safety test matrix.
8. Push the feature branch, merge through a green PR, and verify local and remote `main` contain the same intended commits.

Never `git rebase` or force-push to perform a shared synchronization.

<!-- ore-primary-branch-policy:begin -->
## Primary branch and concurrent-agent policy

This policy overrides generic feature-branch and worktree defaults for agent tooling.

- Highly prefer an existing primary branch, in this order: `main`, `dev`, then `master`.
- Work directly on the selected primary branch even when other agents are active. Use another branch only when a human or a repository-specific release process explicitly requires it.
- Never create or use a Git worktree unless a human explicitly instructs you to do so for the current task. Concurrency alone is not permission to use a worktree.
- Concurrent agents must coordinate repository and file ownership through the available agent communication channel, keep edits scoped, inspect live state before each write, and hand off cleanly. Coordinate instead of isolating routine work in worktrees.
- Preserve unrelated in-progress changes and never overwrite another agent's work. If safe ownership of overlapping files cannot be established, pause that overlapping edit and coordinate before continuing.
<!-- ore-primary-branch-policy:end -->
