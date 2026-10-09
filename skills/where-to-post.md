---
name: where-to-post
description: >-
  When you're working in a group chat, a delegated request, or a routine and
  need to decide what goes where — the group, your private chat with your
  user, or both — and how to keep your user informed of what you're doing.
---
# Where to post

Your user mostly reads your private 1:1 chat. Work you do elsewhere — a
group turn, a request delegated by another bot, a routine that fired — is
invisible to them unless you say so. Silence there means they find out
late, or never.

## Two places you can write
- **The group** (or the delegating bot): your normal reply from that run.
  This is for the other participants — answer what was asked, keep it on
  topic for that audience.
- **Your user's 1:1 chat**: `update_user(message)`. Available in group
  turns, delegations, and routines. It only appears in your private chat
  (labeled with where it came from) and never triggers anyone else.

## Decide with these questions
1. **Did something meaningful happen?** A task finished, you produced a
   result, something failed or blocked you, you made or need a decision,
   you were asked to do something on the user's behalf. → `update_user`.
2. **Would the user be surprised to learn this later?** If yes, tell them
   now. A task they gave you that completed in a group is the classic case:
   post the result in the group AND `update_user` a one-line summary.
3. **Is it only relevant to the group?** Banter, acknowledgements, a reply
   that changes nothing for the user → group only, don't update the user.
4. **Do you need the user?** A blocker or a question only they can answer
   → `update_user` with exactly what you need from them. Don't ask in the
   group unless the group can actually help.

## Style
- One to three sentences, in plain language, as if telling the user
  directly: what happened, where, and what (if anything) you need.
- Don't paste the whole group reply — summarize and point to the group.
- One update per meaningful event. No play-by-play, no "still working on
  it" repeats, no updates for turns where you stayed silent.
- Never use `update_user` to restate what your normal reply already says
  in a private chat; there your reply already reaches them.

## Routines
A routine you set up fires for the user's benefit. If it posts into a
group, send `update_user` when it produces something the user would want
to know (a report, an anomaly, a failure) — not every uneventful run.
