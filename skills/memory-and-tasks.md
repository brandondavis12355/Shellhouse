---
name: memory-and-tasks
description: >-
  When deciding whether to save something for later (a preference, a
  correction, a fact, an assigned job), checking what you already know, or
  finishing a task someone gave you.
---
# Memory and tasks

You don't remember past conversations on your own. Group turns,
delegations and routines each start fresh, with only your system prompt.
Two tools carry things across: `remember` for lasting facts, and
`remember_task` for jobs with an end.

## Which one?
| It's… | Use |
|---|---|
| A standing preference or correction ("always use metric", "my name is Sam") | `remember(text)` |
| A fact you'll need again and shouldn't re-learn (which bot handles travel) | `remember(text)` |
| A job you've been given ("draft the budget summary by Friday") | `remember_task(text)` |
| Something only useful for the next few steps | Neither. Keep it in your reasoning |

## remember
- Save it the moment you learn it; don't wait to be asked.
- One short, plain sentence per memory. Write it so it makes sense with no
  other context: "Prefers replies under five sentences", not "short".
- Your user sees and can delete every memory in your settings. Only the 60
  most recent are kept.
- Before saving, check you don't already have it. Everything remembered is
  already in your system prompt, and `recall_memory(query)` searches it.
- Correct a memory by saving the corrected version; your user can remove
  the old one.

## remember_task, list_tasks, complete_task
- `remember_task` the moment you're given a concrete job. It's the only way
  that job is visible when you're @mentioned about it in a group later.
- `list_tasks` shows your open tasks live, with their ids. Your system
  prompt's list is a snapshot from when the run started.
- `complete_task(id)` as soon as it's actually done (verified, not just
  attempted). Use the exact id from `list_tasks`.
- Only the 20 most recent open tasks are kept: a 21st silently drops the
  oldest. Complete tasks as you finish them so nothing real gets pushed out.

## recall_memory
For the moment you suspect something you were told before applies right
now. Search once, with a specific query (a name, a topic). Searching again
with the same question won't give a different answer, and repeated calls
can get the run stopped for looping.

## Untrusted runs
If your run includes untrusted content (a web page, a friend's message,
downloaded files), memory and task changes are held for your user's review
instead of saved. You'll be told when that happens. Carry on without
relying on them, and mention in your reply what you wanted to save.
