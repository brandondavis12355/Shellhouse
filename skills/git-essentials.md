---
name: git-essentials
description: >-
  Before any git or GitHub command: how your VM connects to GitHub (HTTPS,
  the GITHUB_TOKEN, gh), the exact commands for cloning, committing,
  branching, pulling, pushing, merging and undoing, and what common git
  errors mean and how to fix them.
---
# Git essentials

## How your VM connects to GitHub
- **HTTPS only**: `https://github.com/<owner>/<repo>.git`. The VM has no
  SSH keys, so `git@github.com:` URLs fail.
- Git asks `gh` for sign-in, and gh reads `GITHUB_TOKEN` from the
  command's environment. Commands that talk to GitHub (clone, fetch, pull,
  push, `gh ...`) run with `use_secrets: ["GITHUB_TOKEN"]`. Run them as the
  plain git/gh command alone (no `&&` chains to other programs), so they
  can be approved.
- No token saved yet? Call `request_credentials` once with a
  `GITHUB_TOKEN` field ("GitHub personal access token").
- **Never put the token in a URL or a file.** It's blocked, and git would
  save it in `.git/config`.
- Your commit name and email are already set. Local commands (status, log,
  diff, branch, commit) need no token.

## Everyday commands
| Goal | Command |
|---|---|
| What changed? | `git status`, `git diff`, `git diff --staged` |
| History | `git log --oneline -10` |
| One commit | `git show <hash> --stat` |
| New branch | `git switch -c <your-name>/<task>` |
| Switch branch | `git switch <branch>` (commit or stash first) |
| Stage and commit | `git add <files>`, then `git commit -m "fix: what and why"` |
| Update | `git pull origin main` (token) |
| Others' branches | `git fetch origin` (token), then `git branch -r` |
| Publish your branch | `git push -u origin <branch>` (token) |
| Bring main in | `git fetch origin`, then `git merge origin/main` |
| Set work aside | `git stash`, later `git stash pop` |

- Already cloned? Don't clone again: pull.
- Stage files by name, not `git add -A` or `git add .`, so caches,
  `.venv/`, `node_modules/` and secrets don't slip in. List those in
  `.gitignore`.
- Commit messages: `type: summary` (`feat:`, `fix:`, `test:`, `docs:`),
  under 70 characters.
- Read every output. Only a `git push` line like
  `abc1234..def5678  <branch> -> <branch>` proves a push happened.

## Never judge from a stale checkout
Your local copy only changes when you fetch or pull. Before you say what
is (or isn't) on GitHub, or review someone's work:
1. `git fetch origin` (token).
2. `git log -1 --oneline origin/<branch>`: name that commit hash in your
   reply ("checked origin/prism/tests at 3f2a9c1").
3. Compare remote copies: `git diff --stat origin/main..origin/<branch>`.
4. To run their code: `git switch <branch>`, `git pull`, and check
   `git log -1 --oneline` matches the commit they announced.

## Waiting on someone
If what you need isn't pushed yet, don't keep fetching or re-posting.
Say once what you're waiting for and from whom, then end your turn: you're
woken when they post.

## Undoing safely
| Situation | Command |
|---|---|
| Unstage a file | `git restore --staged <file>` |
| Throw away changes to a file | `git restore <file>` (gone for good) |
| Fix the last unpushed commit message | `git commit --amend -m "..."` |
| Undo a pushed commit | `git revert <hash>` (adds a commit) |
| Back out of a conflicted merge | `git merge --abort` |

Never `git push --force`, `git reset --hard` or `git clean -f`, and never
rewrite commits others have pulled. Stuck? Make a new branch and open a PR
for the goal owner instead.

## Merge conflicts
1. `git status` lists the conflicted files.
2. In each, keep what both sides meant and delete the `<<<<<<<`,
   `=======`, `>>>>>>>` markers.
3. Run the tests, then `git add <file>` and `git commit`.
4. Can't tell which side is right? Ask the author.

## Pull requests
`gh pr create --base main --head <branch> --title "..." --body "..."`
(token). It asks your user, and is blocked in an untrusted run. Check with
`gh pr view <branch>` or `gh pr list`.

## Errors and fixes
| Error | Meaning | Fix |
|---|---|---|
| `could not read Username` | No token on that command | Re-run with `use_secrets: ["GITHUB_TOKEN"]`; still failing, `gh auth setup-git` once with it |
| `Authentication failed` / `403` / `Repository not found` | Token missing, expired or without access, or a typo | Check owner/repo; then ask your user to check the token's access |
| `Permission denied (publickey)` | An SSH URL | `git remote set-url origin https://github.com/<owner>/<repo>.git` |
| `rejected ... (fetch first)` / `non-fast-forward` | GitHub has commits you don't | `git pull origin <branch>`, resolve, test, push again. Not `--force` |
| `src refspec <branch> does not match any` | No commit on that branch, or a typo | `git status`, commit, check `git branch` |
| `Your branch is behind` | Others pushed | `git pull` |
| `detached HEAD` | You checked out a commit | `git switch -c <new-branch>` to keep work |
| `not a git repository` | Wrong folder | `cd /workspace/<repo>` |
| `detected dubious ownership` | Folder owned by another user | `git config --global --add safe.directory /workspace/<repo>` |
| `CONFLICT (content)` | Both sides changed the same lines | See Merge conflicts |

If a fix fails twice, stop varying it: tell your user the command and the
exact error.
