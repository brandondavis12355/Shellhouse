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
- Private repository: use `gh`, which reads the token from the environment
  and never stores it. Your user keeps it as a secret, usually
  `GITHUB_TOKEN`: `run_shell("gh repo clone owner/repo /workspace/repo",
  use_secrets: ["GITHUB_TOKEN"])`. Do this first, before anything else in
  the run, because secret commands are blocked once a run is untrusted. If
  `command -v gh` finds nothing, install it with `sudo apt-get install -y gh`
  (only if sudo is enabled), or ask your user.
- Never put a token in a URL, a file or a commit, and never print it.

## Work in small, checked steps
1. Read before changing: the README, how the project is built and tested,
   and the code around what you're touching (`ls`, `git log --oneline -10`,
   `grep -rn`).
2. Change one thing at a time with `read_file` and `write_file` (write the
   whole file back).
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
- Make a branch for the work: `git checkout -b <short-name>`. (Use this
  form; `git switch -c` is flagged as a stricter action.)
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
