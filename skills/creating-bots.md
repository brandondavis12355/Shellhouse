---
name: creating-bots
description: >-
  When your user asks you to create, recruit or set up a new bot, or a job
  needs a specialist no existing bot covers: deciding whether to, writing its
  name, role and instructions, and briefing it afterwards.
---
# Creating bots

`create_bot(name, tagline, system_prompt)` adds a real, persistent bot to
your user's roster: its own Linux computer, memory and chat in their
sidebar. It always asks your user for approval, and it only works from
your private 1:1 chat, not in group turns, delegations or routines.

## First, decide whether you should
1. **Can you do it yourself in a reasonable number of steps?** Then do.
2. **Does an existing bot already cover it?** Check `list_bots` (live) and
   their roles. If one fits, delegate with `message_bot` instead.
3. **Will this role be needed again?** A new bot is worth it for recurring
   or ongoing work (a researcher, a reviewer, a monitor), not for a single
   one-off task.
4. **Did your user ask for it, or clearly agree?** If not, suggest it and
   let them decide; don't create bots speculatively.

## Write the three fields
- **name**: short, distinct, easy to @mention ("Atlas", "Scout"). Not the
  same as an existing bot: creating a name that exists returns that bot
  (`already_existed: true`) instead of a new one.
- **tagline**: one specific line every bot sees in its directory and uses
  to decide who to delegate to. Say what it handles: "Researches topics on
  the web and reports with sources", not "Helpful assistant".
- **system_prompt** (optional): role instructions added on top of the
  standard ones every bot already has (tools, finishing, verification,
  memory). Write only what this role needs, in 5–15 short lines:
  - what it's for and what good output looks like;
  - which skills to lean on (by name, e.g. `web-research`);
  - what it should not do (out of scope, ask first, never);
  - who to hand results back to, if anyone.

  The bot-role-templates skill has ready-made versions of these for common
  roles. Don't repeat the standard rules: it already has them.

## What the new bot starts with
- The same local model as you (your user can change it in its settings),
  all skills switched on, and the default step and token limits.
- An empty computer, empty memory and no conversation. It can't see your
  files or your chat: anything it needs has to go in your brief.
- Its computer starts in the background, usually within a minute.
  `message_bot` waits for it, so you can brief it straight away.

## Right after creating it
1. **Brief it** with `message_bot`: the goal, the context it needs (paste
   it; it can't see your workspace), any deadlines or constraints, and
   exactly what you want back.
2. **Add it to a group** with `add_bot_to_group` if your user is
   coordinating there (groups hold at most 6 members).
3. **Remember it**: `remember("Scout handles web research")`, so you
   delegate to it next time instead of looking again.
4. **Tell your user** in your reply: the bot's name and role, why you
   created it, what you've asked it to do, and that they can change its
   model, skills or instructions in its settings.

## If something goes wrong
- **Approval denied:** don't try again with a different name. Ask your
  user what they'd prefer, or do the work yourself.
- **`message_bot` says it's still starting:** tell your user and try once
  more later; don't retry in a loop.
- **Its computer failed to start:** tell your user. They can reset it from
  that bot's settings.
