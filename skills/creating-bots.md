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
sidebar. Your user approves each one. It only works from your private 1:1
chat, not in group turns, delegations or routines.

## First, decide whether you should
1. **Can you do it yourself in a few steps?** Then do it.
2. **Does an existing bot cover it?** Check `list_bots` (live). If one fits,
   delegate with `message_bot`. Don't create a second bot for the same role.
3. **Will the role be needed again?** A new bot is for recurring or ongoing
   work (a researcher, a reviewer, a monitor), not a one-off task.
4. **Did your user ask for it, or clearly agree?** If not, suggest it and
   let them decide.

## Write the three fields
- **name**: short, distinct, easy to @mention ("Atlas", "Scout"). A name
  that already exists (any capitalization) returns that bot with
  `already_existed: true` instead of a new one. Treat that as "use this
  bot", not as an error to retry under another name.
- **tagline**: one specific line every bot sees and uses to pick who to
  delegate to: "Researches topics on the web and reports with sources",
  not "Helpful assistant".
- **system_prompt** (optional): role instructions added on top of the
  built-in rules every bot already has (tools, finishing, verification,
  memory). 5–15 short lines, only what this role needs:
  - what it's for and what good output looks like;
  - which skills to lean on, by name (e.g. `web-research`);
  - what it must not do, or must ask first;
  - who it hands results to.

  bot-role-templates has ready-made versions. No secrets or personal data.

## What the new bot starts with
- Your model if you run a local one (your user can change it), and the
  default step and token limits.
- An empty computer, empty memory and no conversation. It can't see your
  files or chat: anything it needs goes in your brief.
- Its computer boots in the background, usually within a minute.
  `message_bot` waits for it, so you can brief it straight away.

## Right after creating it
1. **Brief it** with `message_bot`: the goal, the context pasted in, any
   deadline or constraint, and exactly what you want back.
2. **Add it to a group** with `add_bot_to_group` if your user coordinates
   there (at most 6 members).
3. **Remember it**: `remember("Scout handles web research")`.
4. **Tell your user**: its name and role, why you created it, what you asked
   it to do, and that they can change its model, skills or instructions in
   its settings.

## If something goes wrong
- **Approval denied:** don't retry with a different name. Ask your user
  what they'd prefer, or do the work yourself.
- **"still starting up":** tell your user and try once more later; don't
  retry in a loop.
- **"computer failed to start":** tell your user. They can reset it from
  that bot's settings.
