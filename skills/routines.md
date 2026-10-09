---
name: routines
description: >-
  When asked to remind someone, check something later, or do something on a
  schedule (once, daily, or every N minutes), or to change, pause or remove
  a scheduled routine.
---
# Routines

A routine is a scheduled message to yourself. When it fires, its
instruction arrives as if your user had just typed it, and you handle it in
a fresh run. Your user sees all your routines in your settings and can
remove them.

## Create
`create_routine(instruction, schedule_type, …)`
- `schedule_type: "once"` with `at`: an ISO 8601 date-time in the future,
  e.g. `2026-10-12T09:00:00-07:00`. Work out the user's local time and
  include the offset; ask if the time zone is unclear.
- `schedule_type: "daily"` with `hour` (0–23) and `minute` (0–59).
- `schedule_type: "interval_minutes"` with `minutes`.
- `target_group` (optional): the exact name of a group chat you're in. The
  routine then fires there as an action to carry out and post the result,
  instead of in your 1:1 chat.

## Write the instruction as a request
It will reach you with no memory of today's conversation, so make it
complete and self-contained:
- Good: "Check https://status.example.com and tell me if any service is
  degraded. If everything is green, say so in one line."
- Bad: "do the status thing", or "remind me" with no subject.
For a reminder, put the reminder itself in it: "Remind the user: dentist
appointment at 3pm today."

## Check, change, clean up
- `list_routines`: live list with ids, schedules, and next fire time. Call
  it once before creating (to avoid duplicates) and once after (to confirm
  it took). If the routine isn't in the list, it doesn't exist; create it.
- Creating an identical routine again returns `already_existed: true`. That
  is success, not an error. Don't retry.
- `edit_routine(id, …)`: change only the fields you pass. Use `enabled:
  false` to pause, an empty `target_group` to move it back to your 1:1
  chat. Prefer this over remove-and-recreate.
- `remove_routine(id)` removes one. `remove_routine()` with no id removes
  exact duplicates, keeping one of each.

## When a routine fires
- Do what the instruction says, verify it, and finish.
- Nothing worth reporting? Keep the reply short. If it fired in a group,
  only tell your user (with `update_user`) when there's real news. See the
  where-to-post skill.
- If the instruction no longer makes sense (the thing it checks is gone),
  say so and suggest removing or editing the routine.

## In untrusted runs
If your run has read untrusted content, new or changed routines are held
for your user's approval. Tell them what you scheduled and why.
