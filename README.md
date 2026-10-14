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
![License: MIT](https://img.shields.io/badge/license-MIT-FACC15?style=flat-square)

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
 ┌──────────────── Your Mac ─────────────────┐            ┌──────────── Linux host (~/shellhouse) ────────────┐
 │                                           │            │                                                 │
 │  Shellhouse.app                             │    SSH     │  sandbox-manager   the only privileged service; │
 │   ├─ bots, groups, memory, routines       │  tunnel    │   (unix socket)    creates and drives sandboxes │
 │   ├─ guardrails + approvals + audit log  ─┼───────────▶│        │                                        │
 │   └─ Ollama (local models, Metal)         │            │        ▼                                        │
 │                                           │            │  one Debian desktop container per bot           │
 └───────────────────────────────────────────┘            │  (shell, Chromium, files, own workspace volume) │
                                                          └─────────────────────────────────────────────────┘
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
| [`scripts/`](scripts/) | Host helpers used by `initial_setup.sh` and `uninstall.sh`, and the sshd drop-in for the model proxy |
| `initial_setup.sh`, `build.sh`, `uninstall.sh` | Set up the Linux box, build and install the app, and remove it all again |

## Getting started

You need an Apple Silicon Mac (macOS 14+) with Xcode, and a Linux box (Ubuntu/Debian or Fedora; a spare machine or a VM) that you can reach over normal SSH with a user that has sudo rights.

```bash
git clone https://github.com/brandondavis12355/Shellhouse.git
cd Shellhouse
./initial_setup.sh      # sets up the Linux box over SSH
./build.sh              # builds the app, installs it in /Applications and connects it to the box
```

Then add your first bot from the sidebar's **+** menu. Everything uses the default settings; change them in **Settings**, where every change applies right away.

### What `initial_setup.sh` does

It asks for the Linux box's IP address (or hostname) and your SSH user, then:

1. **Connects over SSH.** It uses your password or SSH key, asks only once, and offers to install your key so later runs don't ask.
2. **Copies the server side** of this repo to `~/shellhouse` on the box. The box's own `.env`, seed folders and manager socket are never overwritten.
3. **Sets up the box.** It asks for your sudo password once:
   - installs Docker and Docker Compose if they're missing, and adds you to the `docker` group;
   - makes sure sshd allows the port and socket forwarding the app uses;
   - writes `.env` with a fresh manager token;
   - builds the sandbox image (the first build takes a while) and starts the sandbox manager.
4. **Prepares the app's settings:** the host, the user and the manager token, in `~/.config/shellhouse`, readable only by you. If the app is already installed it hands them over right away; otherwise `build.sh` does it. The token is never printed. The file is overwritten once the app has it.

Everything it changes on the box is recorded in `~/.shellhouse-install-state`, which is what `uninstall.sh` reverts. It's safe to run again: it picks up where it left off.

**Updating, or moving to a new box.** Run it again with the **same** box to update it in place: its `.env` and manager token are kept, and the image is rebuilt. Run it with a **different** box to move to it (a changeover):

- Everything in the app on your Mac stays as it is: settings, bots, groups, conversations and memories. Only the box it uses changes.
- If the old box is reachable, it offers to bring two things over:
  - its `.env` options (the new box keeps its own token);
  - each bot's workspace files, its `/workspace`, copied box to box through your Mac. Packages installed inside a bot's VM aren't copied.
- Every bot then re-attaches on the new box.
- The old box is left untouched. Once everything works, remove Shellhouse from it with `./uninstall.sh --host OLD-ADDRESS`.

An interrupted changeover resumes when you run the script again with the same new box.

| Option | Effect |
|---|---|
| `--host ADDR` / `--user NAME` | Skip the questions |
| `--with-smolagents` | Also allow the optional smolagents engine's model-proxy forward ([docs/SMOLAGENTS.md](docs/SMOLAGENTS.md)) |
| `--no-sudo-in-sandboxes` | Don't give bots sudo inside their own VMs. By default they have it, so they can `apt-get install` what a task needs |
| `--host-fingerprint SHA256:…` | Verify the box's host key without asking |
| `--rotate-token` | Only replace the manager token, on the box and in the app |
| `--no-ui` | Ask in Terminal instead of dialogs |
| `--yes` | Accept every default (a new box then needs `--host-fingerprint`) |

The box's SSH port must be 22, since the app's tunnel uses it.

**Dialogs:** it asks everything in macOS dialogs: the address, the user, your SSH password, the sudo password (asked once, checked, and sent to the box over the SSH connection, never on a command line), and confirmations. Progress shows in Terminal. Add `--no-ui` to answer in Terminal instead.

**How the connection is protected**

| What | How |
|---|---|
| The box is really your box | On the first connection, you compare the box's SSH host key fingerprint with what the box itself shows (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on its own screen), or pass `--host-fingerprint SHA256:…`. The key is then pinned for these scripts and handed to the app. From then on, a different machine answering at that address is refused. If your Mac already trusts the box, the key must match that one. |
| The app's key can't open a shell | The app's own SSH key is authorized with `restrict` plus port forwarding. It gets no shell, no pty, and no agent or X11 forwarding, and the only commands it may run are its connection test and resource stats ([`scripts/app-ssh-command.sh`](scripts/app-ssh-command.sh)). A stolen copy of it can't open a shell on the box. It can still forward connections from the box, which the tunnel needs: OpenSSH applies a port allowlist (`permitopen`) to socket forwards too, so the manager's socket can't be allowed alone. |
| Only you can reach the manager | `~/shellhouse`, its `.env` (the manager token) and the manager's socket are readable only by your user on the box. |
| No password guessing | Once your own SSH key signs you in, it offers to turn off password sign-in for your user on the box. `uninstall.sh` turns it back on. |
| A fresh token when you want one | `./initial_setup.sh --rotate-token` replaces the manager token on the box, restarts only the manager (bot VMs keep running) and hands the new token to the app. The old token stops working at once. |

### What `build.sh` does

1. Checks Xcode (license, first-launch components). If [Homebrew](https://brew.sh) is missing, it offers to install it with Homebrew's official installer (which asks for your Mac password). Then it installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) with Homebrew if needed.
2. Finds your Apple signing team, or asks for it, and saves it to `macos/Signing.local.xcconfig` (git-ignored).
3. Builds a Release copy and installs it as `/Applications/Shellhouse.app`, quitting a running copy first.
4. Installs [Ollama](https://ollama.com) with Homebrew if it's missing, and pulls the default models: `qwen2.5:7b-instruct` for chat and `nomic-embed-text` for memory search. Skip this with `--no-models`.
5. Starts the app and connects it to the box `initial_setup.sh` prepared:
   - it authorizes the app's own SSH key on the box (only the public key leaves the app);
   - it imports the host and the manager token.

Other options: `--debug`, `--team TEAMID`, `--no-launch`, `--yes`. The build log is in `~/.config/shellhouse/build.log`.

### Before the first `build.sh`: one-time Xcode setup

`xcodebuild` can't sign in to your Apple account by itself, so do this once in Xcode:

1. **Install Xcode** from the App Store and open it once. Accept the license, and let it install its components.
2. **Sign in:** Xcode › Settings › Accounts › **+** › Apple ID. A free personal team works. The team ID is the 10-character code shown for your team.
3. **Create the signing certificate:** in Accounts, select your team › **Manage Certificates…** › **+** › **Apple Development**.
4. **Build once from Xcode**, so it can create the provisioning profile the sandboxed app needs:
   ```bash
   cd macos && xcodegen generate && open "Shellhouse.xcodeproj"
   ```
   Select the **Shellhouse** target › Signing & Capabilities › choose your team, then press ⌘B. You only need to do this again if you change teams.

After that, `./build.sh` handles everything from the command line. If it reports a signing or provisioning error, step 4 is what's missing.

### Removing it

```bash
./uninstall.sh            # cleans the Linux box over SSH, as if Shellhouse had never been there
./uninstall.sh --mac      # also removes the app, its data and its Keychain items from this Mac
```

It asks you to type the box's address to confirm. It removes:
- every container, volume, network and image the stack or the sandbox manager created;
- `~/shellhouse`;
- the app's SSH key;
- the sshd changes;
- the packages and `docker` group membership that `initial_setup.sh` added. Anything that was on the box before stays. Add `--keep-packages` to keep Docker.

### Settings files

**Settings › Backup & restore** exports every setting to one `.shellhousesettings` file:
- app settings;
- each bot's settings;
- each group's settings;
- secrets, only if you choose to include them.

Conversations and memories are never included.

Importing merges: bots and groups are matched by name and created if they're missing. Opening a `.shellhousesettings` file imports it too. A downloaded file asks before it changes anything.

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
| [docs/AGENT-CLI-COMPARISON.md](docs/AGENT-CLI-COMPARISON.md) | How Shellhouse compares to open-source agent CLIs, and what to adopt |

## License

[MIT](LICENSE)

---

<div align="center">
<sub>Self-hosted. Your models, your machines, your bots.</sub>
</div>
