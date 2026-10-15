---
name: git-teamwork
description: >-
  When several bots work on the same repository: branches per member,
  small commits, pulling before and pushing after, merging, and resolving
  conflicts, given that every bot has its own separate VM and clone.
---
# Git teamwork

Every bot has its own VM and its own clone. You only see a teammate's work
after they **push** and you **fetch or pull**. "Done on my VM" means nobody
else has it yet. For exact commands and error fixes, load `git-essentials`.

## Branches and commits
- Work on your own branch: `git switch -c <your-name>/<task>` (e.g.
  `prism/tests`). Push that branch, never `main`, unless your user says so.
- Small commits, one change each: `fix: check_draw ignores full boards
  with a winner`.
- `git status` before committing; add files by name. Never commit caches,
  `.venv/`, `node_modules/` or secrets.

## Sharing work (use_secrets ["GITHUB_TOKEN"])
1. Before starting and before pushing: `git fetch origin`, then
   `git merge origin/main`, and run the tests.
2. Push your branch: `git push -u origin <branch>`. Read the output.
3. Tell the group: branch, commit hash (`git log -1 --oneline`), what it
   contains, and the test command with its result.

## Using a teammate's work
- `git fetch origin`, then `git log -1 --oneline origin/<their-branch>`
  and check it's the commit they announced. Name it in your reply.
- `git switch <their-branch>` and run the tests on your VM before relying
  on it. Their message saying it works is not evidence.

## Merging into main (usually the goal owner)
- Members open a pull request from their branch (see `code-projects` ›
  Finishing work). The owner reviews: `gh pr view <n>`, check out the
  branch, run the tests, then `gh pr merge <n> --merge` (with
  `use_secrets: ["GITHUB_TOKEN"]`). Say what you merged and what you ran.
- Merge one branch at a time and run the full suite after each.
- **Conflicts**: keep both sides' intent, remove the `<<<<<<<`/`>>>>>>>`
  markers, run the tests, commit. Unsure which side is right? Ask the
  author.
- Never `push --force` or rewrite pushed history. A tangle is fixed with a
  new branch and a new PR.

---
Adapted from addyosmani/agent-skills (git-workflow-and-versioning), MIT.
See THIRD-PARTY-NOTICES.txt.
