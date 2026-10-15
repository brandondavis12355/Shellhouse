---
name: where-to-post
description: >-
  When you're working in a group chat, a delegated request, or a routine and
  need to decide what goes where — the group, your private chat with your
  user, or both — and how to keep your user informed of what you're doing.
---
# Where to post

Your user mostly reads your 1:1 chat. Work elsewhere (a group turn, another
bot's request, a routine) is invisible to them unless you say so.

## Two places you can write
- **Where you're working** (the group, or the bot that asked): your normal
  reply from that run. For the other participants: answer what was asked,
  on topic.
- **Your user's 1:1 chat**: `update_user(message)`, available in group
  turns, delegations and routines. It appears only in your private chat,
  labeled with where it came from, and wakes no one.

## Decide with these questions
1. **Did something meaningful happen?** A task finished, a result, a
   failure or block, a decision made or needed, something done on the
   user's behalf → `update_user`.
2. **Would the user be surprised to learn this later?** Tell them now. A task
   they gave you that completed in a group: post the result in the group
   AND `update_user` a one-line summary.
3. **Only relevant to the group?** Group only. And if your reply would only
   acknowledge, agree or repeat ("Thanks!", "Sounds good", "On it"), don't
   post it at all: finish with outcome `silent`.
4. **Do you need the user?** A question only they can answer → `update_user`
   with exactly what you need. Don't ask the group what it can't answer, and
   don't ask the user what you can look up (`recall_memory`, `list_tasks`,
   your files).

## Screenshots, logs and long output
- A screenshot goes where its viewer is. `post_screenshot` posts into the
  chat you're working in: in a group turn, the group. Post one there only
  when the group needs to see it; `update_user` can't carry images.
- Long logs, diffs or test output: never paste them into a group. Save them
  to a file in `/workspace`, then post the path plus the few lines that
  matter (the error, the summary line).

## Style
- One to three plain sentences, as if telling the user directly: what
  happened, where, and what (if anything) you need.
- Summarize and point to the group; don't paste the group reply.
- One update per meaningful event: no play-by-play, no "still working on
  it".
- In your 1:1 chat your reply already reaches the user: no `update_user`.

## Routines
If a routine posts into a group, `update_user` only when it produces
something the user would want (a report, an anomaly, a failure), not on
every uneventful run.
