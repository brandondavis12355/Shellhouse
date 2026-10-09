<div align="center">

<img src="macos/App/Shellhouse/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Shellhouse app icon">

# Shellhouse

**A little office of AI agents that live on your Mac.**

Each bot has its own name, personality, model, memory and persistent Linux computer.
They remember, schedule their own work, and coordinate with each other, all on hardware you control.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-7C3AED?style=flat-square&logo=apple&logoColor=white)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white)
![Python 3.12](https://img.shields.io/badge/Python-3.12-3776AB?style=flat-square&logo=python&logoColor=white)
![Local models](https://img.shields.io/badge/models-local%20via%20Ollama-111827?style=flat-square)

<img src="avatars/blob_purple.svg" width="56" alt=""> <img src="avatars/capsule_cyan.svg" width="56" alt=""> <img src="avatars/diamond_yellow.svg" width="56" alt=""> <img src="avatars/cloud_pink.svg" width="56" alt=""> <img src="avatars/circle_green.svg" width="56" alt=""> <img src="avatars/blob_orange.svg" width="56" alt="">

</div>

---

## What it is

Shellhouse is a native SwiftUI Mac app for running a *roster* of independent AI agents, not a single chatbot. Every bot is a real agent with its own sandboxed Linux desktop, so it can use a shell, a browser, files and the GUI to get work done, then report back.

- **A computer per bot.** Each bot drives its own persistent Debian desktop over SSH: screenshots, clicks, typing, shell and files.
- **Memory that lasts.** Bots keep durable facts and open tasks across conversations, and recall them when they're relevant.
- **Work while you're away.** Bots schedule their own routines ("check this daily", "post a standup every morning") from the menu bar.
- **Teams, not threads.** Bots message each other, delegate, recruit a new specialist, and share group chats with goals and checklists.
- **Guardrails by default.** Shell commands and bot creation ask for approval. Untrusted content can't silently escalate, and every decision is audited.
- **Local-first models.** Models run through Ollama on your Mac. A bot can use any OpenAI-compatible endpoint if you choose.

The full tour of the app is in **[macos/README.md](macos/README.md)**.

## How it fits together

```
 ┌──────────────── Your Mac ────────────────┐            ┌──────────── Linux host (~/shellhouse) ────────────┐
 │                                           │            │                                                  │
 │  Shellhouse.app                             │    SSH     │  sandbox-manager   the only privileged service; │
 │   ├─ bots, groups, memory, routines       │  tunnel    │   (unix socket)    creates and drives sandboxes │
 │   ├─ guardrails + approvals + audit log  ─┼───────────▶│        │                                         │
 │   └─ Ollama (local models, Metal)         │            │        ▼                                         │
 │                                           │            │  one Debian desktop container per bot           │
 └───────────────────────────────────────────┘            │  (shell, Chromium, files, own workspace volume) │
                                                          └──────────────────────────────────────────────────┘
          optional:  group-relay (share groups with friends) · egress-proxy (per-sandbox outbound allowlist)
```

The repo also contains the **Docker/Python reference stack** the app grew out of: a single-agent loop with a web UI (`api/`, `web/`), durable task queue, vector memory, MCP client and deterministic evals. It runs entirely in Docker and is still the design reference for features the Mac app hasn't adopted.

## Repository layout

| Path | What lives there |
|---|---|
| [`macos/`](macos/) | The Shellhouse Mac app: SwiftUI app, `AgentCore` (agent loop, tools, guardrails, model backends), tests |
| [`skills/`](skills/) | Playbooks bundled into the app; a bot loads one only when a task calls for it |
| [`avatars/`](avatars/) | The 64 animated bot avatars (8 shapes × 8 colors) |
| [`sandbox/`](sandbox/) | The Debian desktop image every bot runs in, the in-sandbox agent runner, Firecracker scripts |
| [`sandbox-manager/`](sandbox-manager/) | The privileged service that creates, runs and tears down sandboxes |
| [`egress-proxy/`](egress-proxy/) | Optional outbound-traffic allowlist for sandboxes (compose profile `egress`) |
| [`group-relay/`](group-relay/) | Optional server for sharing group chats with friends (compose profile `relay`) |
| [`api/`](api/), [`web/`](web/), [`evals/`](evals/) | The Docker/Python reference stack and its evaluation suites |
| [`docs/`](docs/) | Security model, guardrails, reliability, egress, Firecracker and design notes |
| [`scripts/`](scripts/) | Host helpers, such as the sshd drop-in for the model proxy |

## Getting started

You need an Apple Silicon Mac (macOS 14+) and a Linux host with Docker that the Mac can reach over SSH. The host can be a spare machine or a VM.

### 1. Linux host setup

The app expects the stack in `~/shellhouse` on the host, because it connects to the manager's socket at `~/shellhouse/sandbox-manager-run/manager.sock`.

```bash
git clone https://github.com/brandondavis12355/Shellhouse.git ~/shellhouse
cd ~/shellhouse
./setup.sh                                           # .env, manager token, docker GID, sandbox seed
docker compose up -d --build sandbox sandbox-manager
```

`setup.sh` writes the manager token to `.env`; you'll paste it into the app. The optional smolagents engine also needs `bash scripts/enable-model-proxy-forward.sh` on the host. Run it with `--dry-run` first to see what it changes.

### 2. The Mac app

```bash
brew install xcodegen
cd macos
echo 'DEVELOPMENT_TEAM = YOUR_TEAM_ID' > Signing.local.xcconfig   # git-ignored
scripts/build.sh                                                   # generate, build, launch
```

Then in **Settings**:

- **Linux host:** enter the host and SSH user, press **Copy authorize command**, run it once in Terminal, then press **Test**.
- **Sandbox manager token:** paste `MANAGER_TOKEN` from the host's `~/shellhouse/.env`.
- **Ollama:** pull a tool-calling model such as `qwen2.5:7b-instruct`.

Add your first bot from the sidebar **+** menu. Building from Xcode and signing are covered in [macos/README.md › Building](macos/README.md#building).

### Or: the Docker reference stack

```bash
./setup.sh
docker compose up -d --build
docker exec agent-ollama ollama pull qwen2.5:7b-instruct
```

Open the web UI at <http://localhost:3000>. The agent's live desktop is embedded on the left; click into it to take over. Every port binds to `127.0.0.1`.

## Testing

```bash
cd macos && swift test                                          # app core: agent loop, guardrails, groups, relay
cd egress-proxy && python -m pytest                             # egress proxy
cd group-relay && python -m pytest                              # friends relay
cd sandbox/agent-runner && PYTHONPATH=src python -m pytest      # in-sandbox agent runner
python evals/run_evals.py --all --model qwen2.5:7b-instruct     # end-to-end evals (reference stack running)
```

Install `pytest` plus the component's own `requirements.txt` first. The egress proxy is standard-library only, but its manager tests also need `sandbox-manager/requirements.txt`; the agent runner pins its dependencies in `sandbox/agent-runner/requirements.lock`.

## Security

The design assumes the model will eventually read something hostile. The short version:

- **Privilege split.** Only `sandbox-manager` touches Docker. The app and the agent loop reach it through an authenticated unix socket and can only act on sandboxes it created.
- **Approval gates.** Arbitrary shell commands and new bots always need your approval. Once a friend's message is in the conversation, file writes, web access and GUI input ask first too.
- **Loopback only.** The Docker stack binds every port to `127.0.0.1`, and the reference API has no authentication, so don't expose it.
- **Secrets stay out of prompts.** Secrets are injected into the sandbox environment at run time, never into model context.

Details, and commands to verify each claim: [docs/SECURITY.md](docs/SECURITY.md) · [docs/GUARDRAILS.md](docs/GUARDRAILS.md) · [docs/EGRESS.md](docs/EGRESS.md)

## Documentation

| Doc | Covers |
|---|---|
| [macos/README.md](macos/README.md) | The app: capabilities, internals, multi-agent design, building |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model and privilege layout |
| [docs/GUARDRAILS.md](docs/GUARDRAILS.md) | How tool calls are classified, approved and audited |
| [docs/RELIABILITY.md](docs/RELIABILITY.md) | Keeping long agent runs on track |
| [docs/SMOLAGENTS.md](docs/SMOLAGENTS.md) | The optional in-sandbox smolagents engine |
| [docs/MODEL_TIERS.md](docs/MODEL_TIERS.md) | Model tiers, thinking and parallel helpers for faster local replies |
| [docs/EGRESS.md](docs/EGRESS.md) · [docs/FIRECRACKER.md](docs/FIRECRACKER.md) | Network policy and microVM isolation |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The reference stack's architecture |

---

<div align="center">
<sub>Self-hosted. Your models, your machines, your bots.</sub>
</div>
