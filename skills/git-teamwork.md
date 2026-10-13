---
name: git-teamwork
description: >-
  When several bots work on the same repository: branches per member,
  small commits, pulling before and pushing after, merging, and resolving
  conflicts, given that every bot has its own separate VM and clone.
---
# Git teamwork

Every bot has its own VM and its own clone. You only see a teammate's work
after they **push** and you **pull**. "It's done on my VM" means nobody
else has it yet.

For the exact commands, connection setup and error fixes, load
`git-essentials`.

## Branches and commits
- Work on your own branch: `git checkout -b <your-name>/<task>` (e.g.
  `prism/tests`). Push that branch, not `main`, unless your user says so.
- Small commits, one change each, with a message that says what and why:
  `fix: check_draw ignores full boards with a winner`.
- Commit only what you meant to: `git status` first; don't commit caches
  (`__pycache__/`, `*.pyc`, `node_modules/`). Add them to `.gitignore`.
- Your git name and email are already set on every VM.

## Sharing work (token: use_secrets ["GITHUB_TOKEN"])
1. Before starting, and before pushing: `git pull origin main` (or rebase
   your branch on it) so you build on the latest code.
2. Run the tests after pulling.
3. Push your branch: `git push -u origin <branch>`.
4. Tell the group what you pushed: branch, commit hash, what it contains,
   how you tested it.

## Using a teammate's work
- `git fetch origin` then `git checkout <their-branch>` (or merge it into
  yours) and run the tests on your VM before relying on it.

## Merging into main (usually the goal owner)
- Merge one branch at a time, run the full suite after each, then push.
- **Conflicts**: open the conflicted files, keep both sides' intent, remove
  the `<<<<<<<`/`>>>>>>>` markers, run the tests, then commit. If you can't
  tell which side is right, ask the author.
- Never `push --force` to a shared branch or rewrite pushed history.

---
Adapted from addyosmani/agent-skills (git-workflow-and-versioning), MIT.
See THIRD-PARTY-NOTICES.txt.
