# Agent guidelines — sonus-auris-ui.dart

Dart/Flutter client — always-on rolling-window audio recorder (a dashcam for audio).

## Command safety — STRICT (all agents MUST follow)

Never run destructive or irreversible shell commands. To remove or move files,
**always go through git** so the change is tracked and recoverable.

**Blacklisted — do NOT run:**
- `rm`, `rm -rf`, `rmdir`, `unlink` — never delete via raw `rm`.
- bulk / indirect deletion: `find … -delete`, `find … -exec rm …`, `xargs rm` — no bypasses of the `rm` ban.
- raw `mv` of tracked files; truncating a tracked file with `>` or `truncate`.
- `git reset --hard`, `git clean -fdx`, `git checkout -- .` / `git restore .` mass-discard.
- `git stash drop` / `git stash clear`, `git branch -D`, `git tag -d` — destroy unmerged work / refs; not on shared branches unless the operator explicitly asks.
- `git push --force` / history rewrites on shared branches (esp. `main`).
- `dd`, `mkfs`, `shred`, recursive `chmod -R` / `chown -R` on broad paths, fork bombs.

**Whitelisted — safe, prefer these:**
- `git rm` / `git rm --cached` — remove files through git (recoverable via history).
- `git mv` — rename/move through git.
- `git restore <path>` (single file), `git revert`, `git stash` (push) — reversible.
- Editing via the editor tools, `git add`, `git commit`, `git switch -c`.

If a genuinely destructive action seems unavoidable, **STOP and ask the operator
first** — do not improvise around this rule.

## Syncing with the remote

"Sync with the remote" (or just "sync") is a **two-way** exchange — pull the
remote's commits down **and** push yours up. It is never push-only, and a clean
local tree does not by itself mean "synced": you are done only once local and
the remote hold the same commits.

To sync:

1. **Commit your work first** (`git add` + `git commit`) so the tree is clean —
   pull/merge only into a clean tree. `git pull` / `git merge` aborts when an
   incoming change touches a file you have edited, and even when it doesn't it
   buries the merge in your uncommitted work. (Can't commit yet? `git stash`,
   then `git stash pop` after step 3.)
2. `git fetch --all --prune` — safe any time; it only updates tracking refs.
3. `git pull` (fetch + merge) — or `git merge` the upstream branch — to
   integrate the remote's commits.
4. `git push` to publish yours.

Integrate with **`git merge` / `git pull`**. **Never `git rebase` to sync** — it
rewrites history and breaks shared branches.

## Organization coordination and authoritative sync protocol

This section extends the repository rules above. Where an earlier description of “sync” is narrower, this section is authoritative for organization-wide requests.

### GitHub ↔ Linear mapping

- GitHub organization: `sonus-auris` — https://github.com/sonus-auris
- Linear workspace: `denman`
- Linear team: `Denman` (`DEN`), ID `eb8ab169-5afe-4b6f-9cab-3f2aa3e887dc`
- Linear project: `github.com/sonus-auris`
- Linear project ID: `40905103-ae88-4186-9cff-858b7b9384d2`
- Linear project URL: https://linear.app/denman/project/githubcomsonus-auris-a557165528ef

Every repository in this GitHub organization maps to that Linear project unless a more-specific nested `AGENTS.md` explicitly names another project.

Before non-trivial work, search the mapped project for an existing issue and update/reuse it rather than duplicating it. If none exists, create an issue in team `DEN` and this project with repository/GitHub links, context, scope, acceptance criteria, risks, and validation steps. Use the issue identifier in branches, commits, and pull requests when practical; link PRs back to Linear and keep status/blockers current. File incomplete, deferred, risky, or follow-up work in Linear before ending. Never commit Linear/GitHub tokens or other secrets.

### Meaning of “sync with remote”

When the operator says “sync with remote,” “sync the org,” “sync all repos,” or “make main branches up to date,” perform the complete organization-wide process below, not merely a pull in the current checkout.

1. Enumerate every public and private repository in `sonus-auris`, including repositories not yet cloned locally. Explicitly report archived/read-only exceptions. Find every local checkout and `git worktree`.
2. Preserve work before integration: inspect status, untracked files, stashes, local and remote branches, tracking refs, and every worktree. Never discard work with hard resets, blanket restores, branch/worktree deletion, or force-pushes.
3. In every writable repository run `git fetch --all --prune --tags`; ensure local `main` tracks `origin/main`; fast-forward when possible and deliberately merge divergent main histories.
4. Inspect every local branch, remote branch, and worktree for commits or intended changes not represented in `main`. Integrate all valuable unique work into `main` by an intent-preserving merge, cherry-pick, or careful reimplementation. Do not blindly merge obsolete/generated history merely to satisfy ancestry; no intended work may remain absent from `main`.
5. Resolve conflicts semantically: understand both sides, surrounding code, history, schemas, callers, and tests; combine compatible intent and redesign where needed. Never globally choose “ours” or “theirs,” and never merely delete conflict markers.
6. Run the repository’s formatting, linting, tests, and build checks. Run `git diff --check`, then scan the entire worktree with `rg -n --hidden -g '!.git' '^(<<<<<<< .+|=======|>>>>>>> .+)$' .` (or equivalent recursive `grep`) and investigate every match.
7. Review all intended tracked and untracked changes and exclude secrets/unwanted artifacts, then `git add -A`, commit accurately, and publish to `origin/main`. If protection forbids direct push, push an integration branch, merge it by PR, and verify the final commit is on `origin/main`. Never force-push `main` without explicit owner authorization.
8. Fetch again and repeat from step 1 until every writable org repository has a clean tree, local `main` equals `origin/main`, every intended branch/worktree change is represented in `main`, checks pass or a concrete Linear blocker is filed, and conflict-marker scans are clean.

Do not claim completion if any repository, branch, worktree, failure, or read-only exception was silently skipped. Report the exact final state and link remaining Linear issues and pull requests.