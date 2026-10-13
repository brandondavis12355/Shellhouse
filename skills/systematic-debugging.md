---
name: systematic-debugging
description: >-
  When something in code doesn't work (a failing test, an error, a crash,
  wrong output, a build that breaks): finding the root cause before
  changing anything, testing one hypothesis at a time.
---
# Systematic debugging

Find the root cause before you fix anything. A fix for the symptom is a
second bug waiting.

## 1. Investigate
- **Read the whole error**: the last line of a traceback names the cause;
  note the file, line and values.
- **Reproduce it** with one command you can run again. If you can't
  reproduce it, gather more data instead of guessing.
- **Check what changed**: `git diff`, `git log --oneline -5`, new files,
  new dependencies.
- **Find where good data turns bad.** Print the values at each step or
  boundary (input → function → output) and run once to see which step is
  wrong. Trace backwards to where the bad value starts.

## 2. Compare
- Find similar code that works and list every difference, however small.
- If you're following an example or documentation, read all of it.
- Check your assumptions about the inputs: is the test's expected value
  actually right? (Work it out by hand.)

## 3. One hypothesis at a time
- Say it: "I think X is the cause because Y."
- Make the smallest change that tests it. One change, then run.
- Wrong? Undo it and form a new hypothesis. Don't stack fixes.

## 4. Fix
- Write a test that reproduces the bug first (test-driven-development
  skill), then the single fix at the source, then run the whole suite.
- No bundled refactoring or "while I'm here" changes.

## When to stop and report
- If three fixes haven't worked, stop: the problem is probably the
  approach, not the details. Tell your user (or the group) what you found,
  what you tried, and what you think needs to change.
- If you don't understand something, say so plainly instead of guessing.
- Don't loop on the same check: re-running an unchanged command gives the
  same answer.

## Red flags
"Just try X and see"; several changes before one run; a fix you can't
explain; "one more attempt" after two have failed.

---
Adapted from obra/superpowers (systematic-debugging) and
addyosmani/agent-skills (debugging-and-error-recovery), both MIT. See
THIRD-PARTY-NOTICES.txt.
