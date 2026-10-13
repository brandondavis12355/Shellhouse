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
- **HTTPS only.** Use `https://github.com/<owner>/<repo>.git`. Your VM has
  no SSH keys, so `git@github.com:` URLs and `ssh` fail.
- **Credentials come from `GITHUB_TOKEN`** in the Mac's Keychain, through
  gh: git is already set up to ask `gh` for GitHub sign-in, and gh reads the
  token from the command's environment. So any command that talks to GitHub
  (clone, fetch, pull, push, `gh ...`) runs with
  `use_secrets: ["GITHUB_TOKEN"]`. Plain GitHub git commands get the token
  attached automatically, but adding it yourself never hurts.
- **Never put the token in a URL** (`https://x-access-token:$GITHUB_TOKEN@...`)
  or a file. It's blocked, and git would save it in `.git/config`.
- **No token saved yet?** Call `request_credentials` once for a
  `GITHUB_TOKEN` field ("GitHub personal access token").
- Your commit name and email are already set (your bot's name). Check
  with `git config user.name`.
- Commands that only look at your local copy (status, log, diff, branch,
  commit) need no token.

## Getting a repository
- `git clone https://github.com/<owner>/<repo>.git /workspace/<repo>`
  (with the token), then `cd /workspace/<repo>`.
- Already cloned? Don't clone again. `cd` in and `git pull`.
- Check where it points: `git remote -v` should show the plain https URL.

## Everyday commands
| Goal | Command |
|---|---|
| What changed? | `git status`, then `git diff` (unstaged) / `git diff --staged` |
| History | `git log --oneline -10`, `git log --oneline --graph --all -20` |
| One commit's content | `git show <hash> --stat` |
| New branch | `git checkout -b <your-name>/<task>` |
| Switch branch | `git checkout <branch>` (commit or stash first) |
| List branches | `git branch -a` |
| Stage and commit | `git add <files>` then `git commit -m "fix: what and why"` |
| Update from GitHub | `git pull origin main` (token) |
| See others' branches | `git fetch origin` (token), then `git branch -r` |
| Publish your branch | `git push -u origin <branch>` (token) |
| Bring main into your branch | `git merge origin/main` after a fetch |
| Set work aside | `git stash`, later `git stash pop` |

- Stage files by name (`git add game.py test_game.py`), not `git add -A`,
  so caches and scratch files don't slip in. Add `__pycache__/`, `*.pyc`,
  `node_modules/`, `.venv/` to `.gitignore`.
- Commit messages: `type: summary` (`feat:`, `fix:`, `test:`, `docs:`),
  under 70 characters, saying what changed and why.
- Read the output of every command. `git push` printing
  `<old>..<new>  <branch> -> <branch>` is what proves a push happened.

## Undoing safely
| Situation | Command |
|---|---|
| Unstage a file | `git restore --staged <file>` |
| Throw away uncommitted changes to a file | `git restore <file>` (gone for good: be sure) |
| Fix the last commit's message, not yet pushed | `git commit --amend -m "..."` |
| Undo a pushed commit | `git revert <hash>` (adds a new commit) |
| Back out of a merge with conflicts | `git merge --abort` |

Never `git push --force` or `git reset --hard` on shared branches, and
never rewrite commits others have pulled.

## Merge conflicts
1. `git status` lists the conflicted files.
2. In each, keep what both sides meant, and delete the `<<<<<<<`,
   `=======`, `>>>>>>>` markers.
3. Run the tests, then `git add <file>` and `git commit`.
4. If you can't tell which side is right, ask the author before choosing.

## Pull requests
`gh pr create --base main --head <branch> --title "..." --body "..."`
(token). Opening a PR is visible outside your VM, so expect your user to
approve it. Check with `gh pr view <branch>` or `gh pr list`.

## Errors and fixes
| Error | Meaning | Fix |
|---|---|---|
| `could not read Username for 'https://github.com'` | No token on that command | Re-run with `use_secrets: ["GITHUB_TOKEN"]` |
| `Authentication failed` / `403` | Token missing, expired or without access | Ask your user to check the token's access to that repo |
| `Repository not found` (private repo) | Same as above, or a typo in owner/repo | Check the URL; then the token's access |
| `Permission denied (publickey)` / `Host key verification failed` | An SSH URL | Use the https URL: `git remote set-url origin https://github.com/<owner>/<repo>.git` |
| `Author identity unknown` | No commit name/email | `git config user.name "<your name>"`, `git config user.email "<name>@shellhouse.local"` |
| `rejected ... (fetch first)` / `non-fast-forward` | GitHub has commits you don't | `git pull origin <branch>`, resolve conflicts, run tests, push again |
| `src refspec <branch> does not match any` | Nothing committed on that branch yet, or a typo | `git status`, commit, check the branch name with `git branch` |
| `Your branch is ahead of 'origin/main' by N commits` | Not pushed yet | Push (to your branch) |
| `Your branch is behind` | Others pushed | `git pull` |
| `detached HEAD` | You checked out a commit, not a branch | `git checkout -b <new-branch>` to keep work, or `git checkout main` |
| `not a git repository` | Wrong folder | `cd /workspace/<repo>` |
| `detected dubious ownership` | The folder is owned by another user | `git config --global --add safe.directory /workspace/<repo>` |
| `CONFLICT (content)` | Both sides changed the same lines | See Merge conflicts |

If a fix doesn't work twice, stop and tell your user what you ran and the
exact error, instead of trying more variations.
