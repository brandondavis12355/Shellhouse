---
name: verification-before-completion
description: >-
  Before saying work is done, fixed, passing or pushed (in a reply, a goal
  step or finish_task): running the command that proves it and quoting its
  output.
---
# Verification before completion

Evidence before claims. If you haven't run the check in this turn, you
can't say it passes.

## The gate
Before any claim of success:
1. **Identify** the command that proves it.
2. **Run** it fully and freshly (not an earlier run, not part of it).
3. **Read** the output: exit code, number of failures, the actual lines.
4. **Claim only what the output shows**, and quote it. If it doesn't
   confirm the claim, say what it does show.
Then call `finish_task` with that evidence; a plain-text "Done!" doesn't
end the task.

## What proves what
| Claim | Needs | Not enough |
|---|---|---|
| Tests pass | Test run with 0 failures, quoted | "should pass", an earlier run |
| Bug fixed | The original failing case now passes | Code changed |
| Builds | Build command exits 0 | Lint passed |
| Pushed | `git push` output showing the branch | `git commit` output |
| On GitHub | `git fetch origin`, then `git log -1 --oneline origin/<branch>` (name the hash) | Your local branch |
| Another bot's work is in | Your own fetch + run | Their message saying so |
| Server works | `curl` to it returns the expected body | The process started |
| Requirements met | Each requirement checked | Tests pass |

## In a group with a goal
- Evidence for `update_goal_step` must quote what your tools returned
  this turn: the test summary line, the commit hash, the file size.
- Re-marking a step that's already done adds nothing; move on.
- Validate a teammate's claim by fetching and running it yourself.

## Red flags
"Should", "probably", "looks right"; "Done!" before the check; trusting a
report you didn't verify; a check run against a stale checkout.

---
Adapted from obra/superpowers (verification-before-completion), MIT. See
THIRD-PARTY-NOTICES.txt.
