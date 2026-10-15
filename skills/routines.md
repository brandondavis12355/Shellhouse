---
name: routines
description: >-
  When asked to remind someone, check something later, or do something on a
  schedule (once, daily, or every N minutes), or to change, pause or remove
  a scheduled routine.
---
# Routines

A routine is a scheduled message to yourself. When it fires, its instruction
arrives as if your user had just typed it, possibly days later and without
today's context. Your user sees all your routines in your
settings and can remove them. If you promise to do something later ("I'll
check tomorrow"), create the routine now; a promise alone does nothing.

## Create
`create_routine(instruction, schedule_type, …)` with an exact schedule:
- `"once"` with `at`: an ISO 8601 date-time in the future with an offset and
  no fractional seconds, e.g. `2026-10-12T09:00:00-07:00`. Use the current
  time and the user's time zone; ask if the zone is unclear.
- `"daily"` with `hour` (0–23) and `minute` (0–59).
- `"interval_minutes"` with `minutes` (1 or more).
- `target_group` (optional): exact name of a group chat you're in. It then
  fires there as an action to carry out and post the result, instead of in
  your 1:1 chat.

"Later", "soon", "regularly" or "in the morning" are not schedules. Pick the
exact time the user meant, or ask once.

## Write the instruction as a request
Make it complete and self-contained: what to check or do, where, and what
to report.
- Good: "Check https://status.example.com and tell me if any service is
  degraded. If everything is green, say so in one line."
- Bad: "do the status thing", or "remind me" with no subject.
For a reminder, put the reminder itself in it: "Remind the user: dentist
appointment at 3pm today."

## Check, change, clean up
- `list_routines` once before creating (is there one doing this already?
  then `edit_routine` it instead of adding a second) and once after, to
  confirm. If it isn't in the list, it doesn't exist: create it.
- Creating an identical routine returns `already_existed: true`. That is
  success. Don't retry.
- `edit_routine(id, …)` changes only the fields you pass: `enabled: false`
  pauses it, an empty `target_group` moves it back to your 1:1 chat. Prefer
  this over remove-and-recreate.
- `remove_routine(id)` removes one. `remove_routine()` with no id removes
  exact duplicates, keeping one of each.

## When a routine fires
- Do what the instruction says, verify it, and finish.
- Nothing worth reporting? One short line (in a group it must still post;
  don't stay silent). In a group, `update_user` only
  for real news (where-to-post skill).
- If the instruction no longer makes sense (the thing it checks is gone),
  say so and suggest editing or removing it.

## In untrusted runs
After reading untrusted content, new or changed routines are held for your
user's approval. Tell them what you scheduled and why.
