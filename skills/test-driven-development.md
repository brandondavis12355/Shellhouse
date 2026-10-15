---
name: test-driven-development
description: >-
  When adding a feature, fixing a bug or changing behaviour in code:
  writing a failing test first, watching it fail for the right reason,
  making it pass with the smallest change, then cleaning up.
---
# Test-driven development

If you didn't watch the test fail, you don't know it tests the right thing.

## The cycle
1. **Red: write one failing test** for one behaviour, with a clear name and
   the exact expected value, in a test file (`test_<module>.py`), not a
   long `python3 -c "…"` you'll paste again and again.
2. **Watch it fail.** Run it. It must fail (not error), with the message
   you expected, because the feature is missing, not because of a typo.
   - Passes immediately? It tests existing behaviour: fix the test.
   - Errors? Fix the error and run again until it fails properly.
3. **Green: the smallest code that makes it pass.** No extras.
4. **Watch it pass**, then run the whole suite. A test that still fails
   means fixing the code, not weakening the test.
5. **Refactor**: remove duplication, improve names, keep the suite green.
6. Repeat for the next behaviour.

## Check the expectation, not just the code
Before calling a failure a bug, confirm the test is right: print the input
and work out the answer by hand. Example: `X O X / O X O / X O X` is not a
draw; X holds both diagonals, so `check_winner` returning `"X"` is correct
and the test is wrong. Only report a bug in someone else's code once
you've shown the code is wrong.

## Running tests in the VM
- Python: `python3 -m unittest -q` (always available). For pytest, use the
  project's venv: `.venv/bin/pip install pytest`, then
  `.venv/bin/python -m pytest -q`. System pip refuses installs (PEP 668).
- Node: `npm test`. Use the project's own runner when it has one.
- Read the output: count passes and failures. Never pipe to `|| true` or
  trust the exit code of a chained command.
- Slow suite (over two minutes)? `run_shell` with `background: true`, then
  `check_job(job_id, wait_seconds: 110)`.

## Good tests
- Test real behaviour, not mocks. One behaviour per test.
- Name the code change that would make the test fail before writing it.
- Cover the edges: empty, full, invalid input, out of range, duplicates.

## Red flags: stop and start over
Code before the test; a test that passed the first time; a failure you
can't explain; "I'll add tests later".

---
Adapted from obra/superpowers (test-driven-development), MIT. See
THIRD-PARTY-NOTICES.txt.
