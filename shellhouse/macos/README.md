# 🤖 Shellhouse

**A little office of AI agents that live on your Mac.**

Not one chatbot — a *roster*. Each bot gets its own name, its own
personality, its own persistent Linux sandbox, and its own model (a local
Ollama model by default, or any OpenAI-compatible endpoint if you want one
bot to reach further than the rest). They remember things. They schedule
their own reminders. They talk to *each other* when a job is outside their
lane. And when you're not looking, they keep working — the app lives in
your menu bar, not just your Dock.

```
┌─────────────┐        message_bot         ┌─────────────┐
│  Mr. Smith   │ ─────────────────────────▶ │  Tai Lung    │
│ Project Mgr  │ ◀───────────────────────── │ Main Engineer│
└──────┬───────┘                            └──────┬───────┘
       │                                           │
       │              group chat: "VirusProgramming"
       │        ┌──────────────┬──────────────┬────┘
       ▼        ▼              ▼              ▼
   own chat   Bugbot        Dr. EggBot       Cleo
  (private)  (debugging)  (bot creation)  (marketing)
```

Every bot in that picture is a real, independent agent — its own sandbox,
its own memory, its own opinions about whether it needs to say anything at
all.

## Why this exists

Most "AI agent" demos are one model with a system prompt bolted on. This is
what happens when you take that idea seriously enough to ask: *what if the
agents had to coordinate with each other, remember things across sessions,
and act while you're at lunch?* That's a very different, much harder
product — and this is the part of the codebase where all of that friction
actually got solved.

## What a bot can actually do

| Capability | How |
|---|---|
| **Drive a real Linux desktop** | Its own persistent sandbox over SSH — screenshots, clicks, typing, shell, files. Not a text-only stub. |
| **Remember durable facts** | `remember` / `recall_memory` — proactive, deduped, capped, resent every conversation. |
| **Carry a task across contexts** | `remember_task` / `complete_task` — a job assigned in your private chat is still visible if that same bot gets @mentioned in a group later. |
| **Schedule its own future** | `create_routine` — "remind me," "check this daily," "post a standup every morning" — fires even if you're not watching. |
| **Ask another bot for help** | `message_bot` — delegates privately, waits for the answer, relays it back. Both sides remember the exchange happened. |
| **Recruit a specialist** | `create_bot` — spins up a brand-new bot, its own sandbox included, when nobody on the roster fits the job. |
| **Know when to shut up** | Group chats are opt-in per turn — a bot only speaks when @mentioned or when it genuinely has something to add. Everyone else stays quiet, on purpose. |
| **Keep a long-running conversation cheap** | Once a chat's history gets big, it's auto-summarized behind the scenes — you can still scroll back through everything; the *model* just doesn't have to re-read all of it every time. |

## The pieces

```
macos/
├── App/AICompute/        ← the actual app (SwiftUI + the Bot/GroupChat logic)
├── Sources/AgentCore/     ← the agent loop, tools, model backends, sandbox protocol
├── Sources/AgentUI/       ← shared UI components
└── Sources/AgentCLI/      ← aic — a command-line doctor/debug tool
```

- **`AgentRuntime`** — the ReAct loop. Call the model → dispatch tool
  calls → repeat until `finish_task`. Plain text alone never ends a
  turn, on purpose — a model narrating intent instead of doing the
  work is the single most common failure mode of agent loops, and this
  one refuses to let that count as "done."
- **`ToolRegistry`** — everything a bot can reach: filesystem, shell,
  screenshots, GUI input, plus the memory/task/routine/bot-directory
  tools above.
- **`PolicyEngine`** — every tool is `.allow`, `.requireApproval`, or
  `.deny`. Arbitrary shell commands (and creating bots) always stop for
  an approval card; per-binary and "allow all shell" grants exist but never
  cover chained commands, interpreters, or commands that use secrets.
  File writes, web access and GUI input are allowed by default, and ask
  first whenever a friend's message is in the conversation (shared groups).
- **Skills** (`../skills/*.md`, 47 and counting) — lazily-loaded
  playbooks a bot pulls in only when the task actually calls for it,
  instead of stuffing every possible instruction into every prompt.
- **The Debug Console** (Settings → Debug) — a live, filterable feed of
  every bot's raw activity: status, tool calls, token stream — including
  the group turns and delegations that are otherwise invisible black
  boxes in the normal chat UI.

## Requirements

- Apple Silicon Mac, macOS 14+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`): the Xcode project is generated from `project.yml`, not stored in the repo
- [Ollama](https://ollama.com) (native, Metal-accelerated — the app
  supervises it for you, no need to run `ollama serve` by hand)
- A Linux host reachable over SSH, running the sandbox-manager service
  from the root of this repo (each bot's "computer" lives there)

## Building

```bash
cd macos
xcodegen generate        # regenerates the .xcodeproj from project.yml
open "Shellhouse.xcodeproj"
```

Set your own signing team in Xcode (Signing & Capabilities), or put it in
`project.yml` locally before generating. Re-run `xcodegen generate` after
pulling changes that add or remove files. Build and run from Xcode with your own signing team — the app is
sandboxed (`com.apple.security.app-sandbox`), so it needs a real
provisioning profile, not just a debug build.

First launch: add the sandbox-manager's shared token in Settings, pull a
tool-calling-capable model (`qwen2.5:7b-instruct`, `llama3.1:8b-instruct`,
or similar), and add your first bot from the sidebar `+` menu.

## What makes the multi-agent part hard (and what's actually handled)

If you've tried building something like this yourself, you already know
where it gets ugly. This codebase has explicit, deliberate answers for:

- **One bot's "Stop" button cancelling a *different* bot's work** — a
  delegation or group turn runs as an independent task, immune to the
  requesting chat's own cancellation.
- **Two runs racing for the same sandbox** — a FIFO run-lock, with
  cancellation-while-queued handled correctly (no double-released locks,
  no orphaned continuations).
- **A model that forgets to call `finish_task`** — forced to retry, and
  explicitly told to reuse its own already-good answer instead of
  drifting into a worse one on the second try.
- **Duplicate everything** — routines, bots, remembered facts, and
  delegation memories are all checked for exact duplicates before being
  created, not just cleaned up after the fact.
- **A pending approval card outliving the run that raised it** — tagged
  by which run owns it, so "Stop" only ever resolves *its own* chat's
  approval, never someone else's mid-delegation.
- **A deleted bot resurrecting its own files** — an in-flight task or a
  pending routine timer used to keep a "deleted" bot's data alive on
  disk; both get shut down before deletion now.

None of this is theoretical. Every item on that list was a real bug,
found by actually running this thing with several bots talking to each
other, and fixed in place.

## Status

Actively developed, self-hosted, no cloud model calls — same principle as
the Python/Docker reference build at the repo root, just running natively
on the Mac instead of in containers. See `../docs/MACOS-NATIVE.md` for the
original design notes (some now superseded by what's actually built) and
`../docs/SECURITY.md` for the privilege split between the app and the
sandbox host.

## Goals, asynchronous groups and friends

- Group members run **concurrently** and reply as soon as they're ready; @mentions
  keep the conversation going (`GroupChatSession`, `GroupWakePlanner`).
- A group can have a **goal** with a checklist; only evidence-backed step
  completions count as progress, and a stall pauses the group
  (`GroupGoal`, `goal-driven-work` skill).
- **Friends** share groups through the opt-in `../group-relay` service:
  invite codes, signed requests, pinned TLS, friends' text treated as untrusted
  (see `../docs/SECURITY.md`). Groups friends invite you to appear under
  "Shared with me".
