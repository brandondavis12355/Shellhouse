---
name: code-review
description: >-
  When asked to review code (a teammate's branch, a pull request, your own
  change before pushing), or when you receive review feedback on your
  code: what to check, how to report it, and how to respond.
---
# Code review

## Reviewing
1. **Understand the goal**: what was the change meant to do?
2. **Get the latest code and run it.** `git fetch origin`, then
   `git log -1 --oneline origin/<branch>`: name that commit in your review.
   `git diff --stat origin/main..origin/<branch>` shows what changed.
   `git switch <branch>`, `git pull`, run the tests yourself. A review that
   didn't run anything says so.
3. **Read the tests first** (`read_file`): do they test the behaviour that
   matters, including edge cases? Are their expected values right?
4. **Then the code**, on five axes:
   - **Correctness**: does it do what was asked? Edge cases, errors,
     off-by-one, wrong types.
   - **Simplicity**: could it be shorter or clearer?
   - **Design**: does it follow the project's patterns, in the right
     module?
   - **Security**: untrusted input validated, no secrets in code or logs,
     no injection (shell, SQL, paths), no `.venv`/`node_modules` committed.
   - **Performance**: obvious waste only (repeated work in loops).
5. **Report findings by severity**, each with file:line, the problem, why
   it matters and a fix:
   - **Must fix**: bugs, wrong results, security problems, failing tests.
   - **Should fix**: maintainability problems.
   - **Nit**: style; optional.
   Lead with the result: "Approve (at 3f2a9c1)", or "Needs changes: 2
   must-fix".

Be honest: no rubber-stamping, don't soften real bugs, and quantify
("crashes on an empty board").

## Receiving feedback
1. Read all of it first, and restate each point in your own words.
2. **Verify** each suggestion against the code: run it. A reviewer can be
   wrong.
3. Fix valid points one at a time (`edit_file`), testing each. Push back
   on wrong ones with evidence (the command and output).
4. Reply with what you changed, not thanks: "Fixed: board indexing in
   main.py (commit abc1234); tests pass."

---
Adapted from addyosmani/agent-skills (code-review-and-quality) and
obra/superpowers (receiving-code-review), both MIT. See
THIRD-PARTY-NOTICES.txt.
