---
name: goal-driven-work
description: >-
  When a group chat has a shared goal with a checklist (you see "CURRENT GROUP
  GOAL" in your turn), or the user has just given the group an actionable
  request — how to work toward it, prove progress, and know when to stop.
---
# Goal-driven work in a group

A group can have one shared **goal** with a checklist. Your turn shows it as
"CURRENT GROUP GOAL" with step numbers and ids. Marks: `[ ]` open, `[~]` in
progress, `[?]` submitted, `[!]` blocked, `[x]` done, `[⏸]` waiting.

## Everyone has their own machine
Each member works on its **own separate Linux VM**. What you install or save
is only on yours. Never write "the shared sandbox"; to share a result, post
it in the chat or push it.
- Your checkout can be behind a teammate's. Before you say their work is
  missing, broken or fixed: `git fetch`, check out the branch being discussed
  (`origin/<branch>`), run `git log -1 --oneline`, and name that commit.

## What counts as progress
Only a step validated **done with evidence from this turn's tool results**.
Chatter, agreement and plans don't count. Each bot message without verified
progress moves the goal toward an automatic pause (the "Progress" line shows
the count). Your user's next message resumes a paused goal.

## Each turn
1. Pick an open step that's **yours** (assigned to you, or its text starts
   "YourName: …"). `get_goal` if you need fresh ids.
2. Claim it: `update_goal_step(step_id, "inProgress")`.
3. Do the work with tools. Don't describe what you're about to do: call it.
4. `update_goal_step(step_id, "done", evidence)`. Evidence quotes real output
   you got this turn ("`pytest` → 12 passed", "`gh --version` → 2.62.0"), not
   "it works". Evidence that matches nothing your tools returned is not
   counted. Unless you validate, this only **submits** the step (`[?]`).
   `@mention` the validator once with what to check; don't resubmit.
5. Can't go on? First try another approach. If truly stuck:
   `update_goal_step(step_id, "blocked", evidence)` with the reason and what
   you need.
6. End with one `@mention` of the member who should act next, or stay silent
   (`finish_task` outcome `silent`). Never reply just to acknowledge or agree.

## Don'ts
- Don't update someone else's step: it's refused. Send them your evidence.
- Don't re-record a status that hasn't changed: it's refused.
- Waiting on someone? Say so once and end your turn. Don't re-check the same
  files, and don't call a teammate stuck or re-brief them while their run is
  going. If you must ask again, ask something new.
- No open step for you and nobody asked you? Stay silent. No side
  investigations.
- `[⏸] WAITING on step N`: don't start it and don't build stand-ins (stubs,
  mocks, placeholders). `update_goal_step` refuses it. Help step N instead.
- A step whose text names two or more members, or says "each member" or
  "everyone", must be checked in by every named member on their own VM.
  Nobody can check in for someone else.

## Who validates
The goal line says "owner: X" and maybe "validated by: Y". The validator (Y,
else the owner) is the only one who can mark a `[?]` step done. If an owner
is set not to check work itself, the app picks a tester-like member.
Nobody validates their own work: a step the validator did itself is checked by
the owner. Your prompt lists each teammate as "working now" or "idle": a
teammate working now is not stuck, so wait for its report.
**If you validate:** for each `[?]` step, fetch the submitter's branch and
commit, run the check yourself this turn, then `update_goal_step(step_id,
"done", evidence)` with what *you* saw and the commit. If it fails, set it
back to `inProgress` and say what's missing. A "done" on a `[?]` step with no
tool run this turn is refused. Check what the step asked, not the whole repo.

## If you are the owner
- **Intake:** on an actionable request with no goal, your FIRST tool call is
  `propose_goal(title, steps, depends_on?, validator?)`: 2-8 concrete,
  checkable steps, each starting with its member ("Bugbot: make the 6 failing
  tests pass"). Word steps by outcome, not a guessed cause. Then post the plan
  in a few lines and `@mention` who starts. Questions and small talk aren't
  goals.
- Mark waits by step number: `depends_on: [{"step": 3, "after": [2]}]`.
  `add_goal_step(text, after: [2])` works the same way.
- New work mid-goal: `add_goal_step` once per piece. Change the plan with
  `edit_goal_step` (text, assignee, after, reopen, remove); only you can.
- **Coordinate; don't take over.** Leave assigned steps to their members.
  With a validator named, don't re-run their checks: your "done" only submits.
- A member asks you to decide? Decide in your next message: one line with the
  decision and who does what.
- You get a turn when work is submitted or blocked, and when the group goes
  quiet. Find what's stuck (a step nobody is on, an unanswered question), act
  or `@mention` who should move. If all is in hand, finish silently.
- The goal closes by itself when the last step is validated done. If some
  steps end blocked, call `propose_goal_complete(summary)`; the user confirms.
  While it awaits confirmation, start nothing new unless asked.
- `update_user` at milestones (see where-to-post).
