---
name: code-projects
description: >-
  When asked to write a program or script, work in a code repository
  (clone, change, test, commit, push, open a pull request), or fix or
  explain how some code behaves.
---
# Code projects

You do code work yourself, on your own computer. Python 3 (with venv),
Node.js and npm, and git are installed. Work in `/workspace/<project>/`.

## Plan the work in two runs
Downloads (cloning, `pip install`, `npm install`) make a run untrusted.
In an untrusted run, pushing, opening pull requests, anything that uses a
secret, and `sudo` are all blocked. So split repository work:
1. **Setup run:** get the code and install dependencies.
2. **Work run** (your user sends a new message, such as "go ahead"):
   edit, test, commit, push and open the pull request. Don't download
   anything in this run.
Tell your user when setup is done and that the next message starts the
work.

## Getting the code
- New project: `mkdir -p /workspace/<name> && cd /workspace/<name> && git init`.
- Public repository: `git clone <url> /workspace/<name>`.
- Private repository (or a clone that fails with "could not read
  Username", "Authentication failed" or "Permission denied (publickey)"):
  1. Don't retry it, and don't switch to ssh: the VM has no keys. It
     needs a token.
  2. No `GITHUB_TOKEN` saved yet? Call `request_credentials` with a
     `GITHUB_TOKEN` field ("GitHub personal access token").
  3. Once per VM: `run_shell("gh auth setup-git", use_secrets:
     ["GITHUB_TOKEN"])`. Git then asks gh for GitHub sign-in, and gh reads
     the token from the environment of each command. Nothing is stored.
  4. Then plain git, with the token for that one command:
     `run_shell("git clone https://github.com/owner/repo.git /workspace/repo",
     use_secrets: ["GITHUB_TOKEN"])`; the same for `git pull`, `git fetch`
     and `git push origin <your-branch>`.
  **Never put a token in a URL** (`https://x-access-token:$GITHUB_TOKEN@...`):
  git saves the URL, token included, in `.git/config`. It's blocked.
  Do this before browsing or downloading anything else in the run, because
  secret commands are blocked once a run is untrusted.
- In a group, only the member doing the clone asks for the token; the
  others wait for its result instead of trying the same clone.
- Never put a token in a URL, a file or a commit, and never print it.

## Doing the work well
For anything beyond a one-line fix, load the skill for the stage you're in:
- `planning-code-work`: read first, decide files and interfaces, break the
  work into small checked tasks (and goal steps in a group).
- `incremental-implementation`: build in small working slices, commit each.
- `test-driven-development`: failing test first; check the test's own
  expectation before calling something a bug.
- `systematic-debugging`: root cause before fixes, one hypothesis at a time.
- `verification-before-completion`: run and quote the check before saying
  it's done.
- `code-review`: reviewing a teammate's change, or answering review.
- `clean-and-secure-code`: readable code, untrusted input, secrets.
- `git-essentials`: how to connect to GitHub, exact git commands, and what
  git errors mean.
- `git-teamwork`: branches, pull before push, merging with other bots.

## Work in small, checked steps
For anything with several steps, keep a plan with `update_plan` and mark
each step done as you go; you can't finish while steps are still open.

1. Read before changing: the README, how the project is built and tested,
   and the code around what you're touching (`ls`, `git log --oneline -10`,
   `grep -rn`).
2. Change one thing at a time: `read_file`, then `edit_file` with the
   exact lines to replace. Use `search_files` / `find_files` to locate code.
   `write_file` is for new files or complete rewrites.
3. Run it. Use the project's own test command (`pytest`, `npm test`, a
   Makefile target) after every meaningful change. Read the output.
4. Fix what broke before moving on.

## Dependencies
- Python: `python3 -m venv .venv` inside the project, then
  `.venv/bin/pip install -r requirements.txt`.
- Node: `npm install` inside the project folder.
- Both are downloads, so they make the run untrusted. Don't install
  anything the task doesn't need.

## Branches and commits
- Make a branch for the work: `git checkout -b <short-name>` (or
  `git switch -c <short-name>`).
- `git add` the specific files you changed, then `git commit -m "<what
  and why, in one line>"`. Check `git status` and `git diff --staged`
  first, so you don't commit stray files, build output or anything
  secret.
- Set a name and email only if your user tells you which to use.

## Pushing and pull requests
- `git push -u origin <branch>` always asks your user, with a strict
  approval. Push your branch and open a pull request
  (`gh pr create --fill`, with `use_secrets: ["GITHUB_TOKEN"]`); don't push
  to `main` unless they say so.
- Both are blocked in an untrusted run. If you hit that, the work is still
  committed locally: tell your user and ask for a new message to push from
  a fresh run.
- Force-pushes, `git reset --hard`, `git clean -f`, deleting branches and
  discarding changes are destructive. Avoid them, and say why if one is
  truly needed.

## Finishing
Report what you changed (files and a one-line summary each), how you
verified it (the test command and its result), and where it is: the path,
the branch, or the pull-request link.
