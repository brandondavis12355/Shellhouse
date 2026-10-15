---
name: incremental-implementation
description: >-
  While writing code for a multi-part change: building it in small
  working slices, testing and committing each one, and keeping scope
  tight.
---
# Incremental implementation

Build in small slices that each leave the program working.

## The cycle
1. Implement the smallest complete piece (one function with its test, one
   path end to end): `read_file`, then `edit_file`.
2. Run the tests, or the program, for what you changed (`run_shell`).
3. Read the output and check it's what you expected.
4. Commit it: `git add <files>`, `git commit -m "feat: what it does"`.
5. Move on to the next slice; don't restart.

## Rules
- **Call, don't narrate.** Each step is a tool call, not "Next I'll…".
- **Simplest thing that works.** No abstractions before the third use, no
  options nobody asked for.
- **Stay in scope.** Do what the task asks; note other problems for
  later.
- **One thing per commit.** A feature, a refactor and a config change are
  three commits.
- **Keep it runnable.** Never leave the code broken between slices; if a
  slice gets too big, split it.
- **Edit, don't rewrite.** `edit_file` after reading (several changes:
  one call with `edits`); `write_file` only for new files.
- **Don't re-run unchanged checks.** After a passing run, run again only
  when the code has changed.

## Slicing options
- **Vertical**: one feature path through every layer.
- **Contract first**: agree the interface (signatures, data shapes), then
  build each side against it. Best when several bots share the work.
- **Risk first**: do the uncertain part first, so you learn early if the
  plan needs to change.

---
Adapted from addyosmani/agent-skills (incremental-implementation), MIT.
See THIRD-PARTY-NOTICES.txt.
