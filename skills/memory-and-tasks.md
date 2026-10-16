---
name: memory-and-tasks
description: >-
  When deciding whether to save something for later (a preference, a
  correction, a fact, an assigned job), checking what you already know, or
  finishing a task someone gave you.
---
# Memory and tasks

You don't remember past conversations on your own. Group turns, delegations
and routines each start fresh. Two tools carry things across: `remember` for
lasting facts, `remember_task` for jobs with an end.

## Which one?
| It's… | Use |
|---|---|
| A standing preference or correction ("always use metric", "my name is Sam") | `remember(text)` |
| A lesson you'll need again (a fix that worked, a quirk of this repo or VM) | `remember(text)` |
| A job you've been given or promised ("draft the budget summary by Friday") | `remember_task(text)` |
| Something only useful for the next few steps | Neither. Keep it in your reasoning |
| A password, token, key or personal data | Never. Use `request_credentials` |

## remember
- Save it the moment you learn it; don't wait to be asked.
- Save the point, not the message. Boil what you learned down to the one or
  two sentences you'll actually need later (the rule, the fact, the exact
  value, path or command) and drop the rest: the story, the back-and-forth,
  pasted logs or code. Under 300 characters; a longer note is refused and
  you rewrite it shorter. If it holds several separate facts, save each
  as its own note.
- It must make sense on its own: "Prefers replies under five sentences",
  not "short".
  - Bad: the user's whole paragraph about how deployments should work.
  - Good: "Deploys: run `make release` from main, never from a feature
    branch."
- Dates and names matter: keep them. Chatter, greetings and what you did
  step by step don't.
- Your system prompt shows your most important notes, and the ones relevant
  to each message come with it. `recall_memory(query)` searches the rest.
- A near-copy of an existing note replaces it, so to correct a memory, save
  the corrected version. Your user sees and can delete every memory in your
  settings; the least important are dropped when there are too many.
- A short note of each answered `message_bot` exchange is usually saved for
  you automatically; don't `remember` it again.

## remember_task, list_tasks, complete_task
- `remember_task` the moment you're given a concrete job or promise one ("I'll
  send it tomorrow"). It's the only way that job reaches your group turns and
  delegations. If it has a time, also `create_routine` (routines skill).
- `list_tasks` shows your open tasks live, with ids (the system prompt's
  list is from when the run started).
- `complete_task(id)` once it's verified done, with the exact id from
  `list_tasks`.
- Only the 20 newest open tasks are kept: complete tasks as you finish.

## Look it up before asking
Before asking your user something they may already have told you (a
preference, a name, a path, what you were working on), check your notes,
`recall_memory` and `list_tasks`. Search once, with a specific query (a
name, a topic). The same search again gives the same answer, and repeated
calls can get the run stopped for looping.

## Untrusted runs
If your run includes untrusted content (a web page, a friend's message,
downloaded files), memory and task changes are held for your user's review,
or refused. You'll be told which. Carry on without relying on them, and
mention in your reply what you wanted to save.
