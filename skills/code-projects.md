---
name: code-projects
description: >-
  When asked to write a program or script, work in a code repository
  (clone, change, test, commit, push, open a pull request), or fix or
  explain how some code behaves.
---
# Code projects

You do code work yourself, on your own VM, by calling tools. Python 3 (with
venv), Node.js and npm, git and gh are installed. Work in
`/workspace/<project>/`.

## Rules that prevent most failures
- **Do, don't announce.** "I'll run the tests" is not a step; the
  `run_shell` call is. Every reply in a task either calls a tool or calls
  `finish_task`. Plain text never ends a task.
- **Look, don't guess.** Find files with `list_files` / `find_files` and
  code with `search_files` before naming a path. Check a program exists
  with `command -v <name>`. Never invent commands, flags, versions or
  file names: read `--help`, the README or the code.
- **Read before you edit; edit, don't rewrite.** `read_file`, then
  `edit_file` (several changes in one call with `edits`). `write_file` only
  for new files.
- **Once is enough.** Don't re-read a file you just read or re-run an
  unchanged command: the answer won't change.
- **Prove it.** Never say done, fixed or passing without running the check
  in this turn and quoting its result (`verification-before-completion`).
- **Blocked is the last answer.** A blocked or failed action usually has
  another route (the message often names it). Try that, or finish the
  parts you can, before `finish_task` with outcome `blocked`.

## Untrusted runs
Downloading (`pip install`, `npm install`, `curl`, cloning an untrusted
repo) or browsing makes the run untrusted. After that, `gh pr create`,
pushing to `main`, secrets other than `GITHUB_TOKEN`, and most `sudo`
commands are blocked; pushing your own branch needs a strict approval. So
clone and install first, and if the PR is blocked, push the branch, then
ask your user for a new message to open the PR from a fresh run.

## Getting the code
- New project: `mkdir -p /workspace/<name>`, then `git init` in it.
- Already cloned? Don't clone again: `git -C /workspace/<repo> pull`.
- Clone with an https URL: `git clone https://github.com/owner/repo.git
  /workspace/repo`. Git already asks gh for GitHub sign-in, so a saved
  `GITHUB_TOKEN` is used.
- Private repo, or "could not read Username" / "Authentication failed":
  1. Don't retry, and don't switch to ssh: the VM has no keys.
  2. No `GITHUB_TOKEN` saved? Call `request_credentials` with a
     `GITHUB_TOKEN` field ("GitHub personal access token").
  3. Run the plain git command alone with
     `use_secrets: ["GITHUB_TOKEN"]`. Still failing? Run
     `gh auth setup-git` once with the same secret, then retry.
- **Never put a token in a URL** (`https://x-access-token:...@`), a file or
  a commit, and never print it. It's blocked.
- In a group, only the member doing the clone asks for the token; the
  others wait for its result.

## Python and Node
- Never install into system Python (PEP 668 refuses): `python3 -m venv
  .venv` once in the project, then `.venv/bin/pip install -r
  requirements.txt`, and run with `.venv/bin/python`. Each `run_shell` is a
  fresh shell, so `source .venv/bin/activate` doesn't carry over.
- Node: `npm install` in the project folder.
- Install only what the task needs. Add `.venv/`, `node_modules/`,
  `__pycache__/` to `.gitignore`; never commit them.
- Servers never run in the foreground (the call would hang): start with
  `run_shell(..., background: true)`, test with `curl
  http://127.0.0.1:<port>/`, read errors with `check_job`, and `stop_job`
  when done.

## The loop
For several steps, keep a plan with `update_plan` (in a group goal, the
goal steps are your plan); `finish_task` "done" is refused while steps are
open.
1. Read first: the README, how it's built and tested, the code you'll
   touch (`git log --oneline -10`, `search_files`).
2. Change one thing: `read_file`, then `edit_file`.
3. Run the project's own test command (`pytest`, `npm test`, a Makefile
   target) and read the output. Fix what broke before moving on.

For bigger work, load the skill for the stage: `planning-code-work`,
`incremental-implementation`, `test-driven-development`,
`systematic-debugging`, `verification-before-completion`, `code-review`,
`clean-and-secure-code`, `git-essentials` (commands and errors),
`git-teamwork` (several bots on one repo).

## Finishing work
Code isn't finished until it's committed, pushed and open for review.
1. **New branch, never main**: `git switch -c <your-name>/<short-task>`.
   Commit there in small commits: `git add <files by name>`, check `git
   diff --staged`, `git commit -m "fix: what and why"`.
2. **Last check**: `git status` (no caches, `.venv`, build output or
   secrets), then run the tests once more and read the result.
3. **Push and PR**: `git push -u origin <branch>`, then `gh pr create
   --base main --head <branch> --title "<what>" --body "<what changed, how
   you tested it (command and result)>"`, each with
   `use_secrets: ["GITHUB_TOKEN"]`. Both ask your user.
4. **Hand over**: in a group goal, @mention the goal owner with the PR
   link, branch and commit hash, and submit your step with that as
   evidence. Don't merge your own PR unless told to. Alone, give your user
   the link.
5. **Never** `git push --force`, `git reset --hard` or `git clean -f` to get
   past a problem: use a new branch instead.
6. Blocked push or PR? The work is still committed locally. Say so, give
   the branch and commit hash. Never say "pushed" or "merged" without the
   push output or PR link.

Then `finish_task` with: files changed (one line each), the test command
and its result, the branch, commit hash and PR link.
