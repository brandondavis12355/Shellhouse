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
   not "it works". A "done" without a tool run this turn is recorded but does
   **not** count.
5. If you can't proceed: `update_goal_step(step_id, "blocked", evidence)` with
   the reason, and say who or what you need.
6. `@mention` the one member who should act next. Don't reply just to
   acknowledge; if nothing is needed from you, stay silent.

## If you are the owner
- On an actionable request with no goal, call `propose_goal(title, steps)` — 2-8
  concrete steps, each checkable — then post the plan briefly and `@mention`
  who should start. Questions and small talk are not goals.
- Adjust the plan with `add_goal_step`.
- When every step is done (or blocked with a reason), call
  `propose_goal_complete(summary)`. The **user** confirms; don't declare it
  finished in chat before they do.
- Use `update_user` at milestones so the user hears about it in their 1:1 chat
  (see where-to-post).

## When the goal is paused or awaiting confirmation
Paused: stop. Only the user's message resumes it. Awaiting confirmation: don't
start new work unless asked.
