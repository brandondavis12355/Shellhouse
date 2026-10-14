---
name: goal-driven-work
description: >-
  When a group chat has a shared goal with a checklist (you see "CURRENT GROUP
  GOAL" in your turn), or the user has just given the group an actionable
  request — how to work toward it, prove progress, and know when to stop.
---
# Goal-driven work in a group

A group can have one shared **goal** with a checklist. Your turn shows it as
"CURRENT GROUP GOAL", with step ids. The point is convergence: everyone works
toward the same finish line, and talking without progress gets the group paused.

## Everyone has their own machine
Each member works on its **own separate Linux VM**. Installing a package or
saving a file affects only your VM. If every member needs something, the plan
needs one step per member (name the VM's owner); to share a result, post it in
the chat. Never write "the shared sandbox".

## What counts as progress
Only a step marked **done with evidence from this turn's tool results**.
Chatter, agreement, and plans do not count. Every bot message with no verified
progress moves the group toward an automatic pause.

## Each turn
1. `get_goal` if you need the current ids.
2. Pick an **open** step that's yours (or unblock someone). Claim it:
   `update_goal_step(step_id, "inProgress")`.
3. Do the work with tools (`run_shell`, files, etc.).
4. Verify it, then `update_goal_step(step_id, "done", evidence)` — evidence is
   what you ran or checked and what it showed ("`gh --version` → 2.101.0"),
   not "it works". **If you are not the goal owner, this only submits the step
   for validation** (it shows as `[?]`). The owner re-checks it with their own
   tools and is the only one who can mark it done. `@mention` the owner after
   submitting; don't resubmit.
5. If you can't proceed: `update_goal_step(step_id, "blocked", evidence)` with
   the reason, and say who or what you need.
6. `@mention` the one member who should act next. Don't reply just to
   acknowledge; if nothing is needed from you, stay silent.

## Steps that wait on other steps
A step marked `[⏸] WAITING on step N` can't start until step N is done.
- Don't work on it, and don't build stand-ins (stubs, mocks, placeholder
  files) for what it needs: that work gets thrown away or conflicts.
- If all your steps are waiting, say so in one line and stop, or offer to
  help with the step everyone is waiting on.
- `update_goal_step` refuses to start or finish a waiting step.

## If you are the owner
- When a member asks you to decide (which approach, whether the code or
  the test is wrong), decide in your next message: one line with the
  decision and who does what. A member left waiting on you stalls the
  whole goal. Don't re-record a step's status that hasn't changed.
- You'll get a **goal review turn** whenever a member submits a step,
  checks in or reports a block, and again every few minutes while
  something is waiting. In it: pull the work onto your VM, run the check
  yourself, then mark the step done (quoting what you saw) or send it
  back with what's missing. Unblock blocked steps or ask the user. When
  every step is done, call `propose_goal_complete`. If nothing needs you,
  finish silently.
- Mark which steps need others with `depends_on` (by step number), e.g.
  tests and the CLI both need the game logic in step 2:
  `depends_on: [{"step": 3, "after": [2]}, {"step": 4, "after": [2]}]`.
  `add_goal_step` takes `after: [2]` the same way.
- On an actionable request with no goal, call `propose_goal(title, steps)` — 2-8
  concrete steps, each checkable — then post the plan briefly and `@mention`
  who should start. Questions and small talk are not goals.
- Adjust the plan with `add_goal_step` and `edit_goal_step` (reword, reassign,
  change what a step waits on, reopen, remove). Members can add steps; only
  the owner edits them. Your user can also edit the plan from the goal card;
  those changes show up as messages.
- You are the **only** one who can mark a step done. Steps shown as `[?]` were
  submitted by a member: validate each yourself (re-run the check, read the
  file, test the result) in this turn, then `update_goal_step(step_id, "done",
  evidence)` with what *you* saw. If it doesn't hold up, set it back to
  `inProgress` and say what's wrong. Never accept a submission on trust — a
  "done" on a `[?]` step without a tool run this turn is rejected.
- When every step is done (or blocked with a reason), call
  `propose_goal_complete(summary)`. The **user** confirms; don't declare it
  finished in chat before they do.
- Use `update_user` at milestones so the user hears about it in their 1:1 chat
  (see where-to-post).

## When the goal is paused or awaiting confirmation
Paused: stop. Only the user's message resumes it. Awaiting confirmation: don't
start new work unless asked.
