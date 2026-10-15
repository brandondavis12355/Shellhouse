---
name: planning-code-work
description: >-
  Before writing code for anything bigger than a one-file fix: reading the
  code first, deciding files and interfaces, breaking the work into small
  verifiable tasks in dependency order, and (in a group) splitting it
  between members.
---
# Planning code work

A plan is the set of decisions someone implementing it can't make alone:
which files, which names and signatures, which values, which test proves
each piece. Make those decisions before you write code.

## 1. Read before you plan
- Read the request and the relevant code: `list_files` / `find_files` for
  the layout, `search_files` for symbols, `read_file` for the code. Never
  plan around a file or function you haven't seen.
- Follow the project's existing patterns (naming, layout, test runner).
  Note risks and unknowns; ask about anything that changes the plan.

## 2. Map files and interfaces
- List the files you'll create or change and what each one is for. One
  clear responsibility per file.
- Write the interfaces as exact signatures, e.g.
  `check_winner(board: Board) -> str | None`. A name used in one task and a
  different name in another is a bug in the plan.

## 3. Order by dependency, slice vertically
- Foundations first: data model, then the logic that uses it, then the
  interface on top.
- Prefer vertical slices (one working path end to end) over layers. Each
  task leaves the program working and testable.

## 4. Write small tasks with a check each
For every task:
- **What it does**, in one or two lines.
- **Files** it touches.
- **Done when**: a specific, testable condition.
- **Check**: the exact command and the output that means it passed
  (`python3 -m unittest -q` → `OK`).
- **Depends on**: earlier task numbers, or none.

A task is one sitting of work with its own test. Avoid steps that decide
nothing ("handle edge cases", "add tests later").

## 5. Self-review the plan
- Every requirement has a task. Names and signatures match across tasks.
- List the inputs most likely to break it (empty, full, invalid,
  duplicate, boundary) and add a test for each.
- If the plan is longer than the code it describes, cut it back.

## Where the plan goes
- 1:1 chat: `update_plan` with the steps (at most 12), and save longer
  plans to `/workspace/<project>/PLAN.md`. Then start the first step at
  once; a plan isn't progress.
- Group with a goal (owner): turn tasks into goal steps with
  `propose_goal`, set `depends_on` from step 4, and give each member work
  in separate files. Put the interfaces in a step's text so everyone codes
  against the same names.

---
Adapted from obra/superpowers (writing-plans) and addyosmani/agent-skills
(planning-and-task-breakdown), both MIT. See THIRD-PARTY-NOTICES.txt.
