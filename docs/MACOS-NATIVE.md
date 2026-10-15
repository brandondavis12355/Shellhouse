# macOS-native architecture

> **Historical design doc.** This was the original plan for an all-local
> Mac build (Virtualization.framework VMs, an XPC sandbox helper, GRDB). The
> shipped app took a different route: each bot's sandbox runs on a Linux host
> reached over SSH, managed by `sandbox-manager`. See
> [`macos/README.md`](../macos/README.md) for how the app works today.

Target: a signed, notarized Swift app that runs the whole AI-computer stack
with no Docker, no Homebrew, no Python at runtime. Apple Silicon only.

The good news is that this isn't a compromise port. macOS has a first-party
equivalent for almost every component, and in three cases the native version
is materially better than what it replaces.

## Component mapping

| Current (Docker) | macOS native | Verdict |
|---|---|---|
| Firecracker microVM | **Virtualization.framework** (`VZVirtualMachine`) | Direct equivalent. Apple's own hypervisor, runs ARM64 Linux guests, needs an entitlement rather than root. |
| Docker desktop container | Same Linux VM | One VM per task, or one persistent VM. Snapshot/save-state exists for pause/resume. |
| noVNC + x11vnc + websockify | **`VZVirtualMachineView`** | **Better.** A native AppKit/SwiftUI view of the guest framebuffer, with mouse/keyboard passthrough built in. Deletes three moving parts and the whole browser-streaming layer. |
| `docker exec` | **vsock** (`VZVirtioSocketDevice`) + guest agent | **Better.** This is the design I recommended over SSH in the Firecracker doc; here it's the obvious path. No sshd in the guest, no key injection, no guest networking needed for exec. |
| Sandbox Manager container + unix socket | **XPC service** (`SMAppService`) | Direct equivalent, and cleaner. The privilege split survives: only the XPC helper holds the virtualization entitlement and talks to the VM. |
| Fernet + `SECRETS_KEY` in `.env` | **Keychain** (`kSecAttrAccessible...`, optional Touch ID) | **Better.** No key sitting next to the database. Secrets become OS-protected, and biometric gating per use is available. |
| Redis queue | **SQLite-backed queue + Swift actors** | Simpler. Redis existed to survive process death across containers; one app process with a durable task table and structured concurrency covers it. |
| Postgres / SQLite via SQLAlchemy | **SQLite via GRDB** (or raw SQLite3) | Direct. GRDB gives migrations, which the Python build lacks. |
| Qdrant | **SQLite + brute-force cosine via Accelerate** | Simpler at this scale. For one user with tens of thousands of evidence rows, a vDSP dot-product sweep is sub-millisecond. Qdrant's HNSW index solves a problem you don't have. |
| Ollama in a container | **Native Ollama**, or **MLX**, or **Foundation Models** | See the decision below. GPU access is the whole point. |
| FastAPI + Next.js/HTML UI | **SwiftUI** | Direct. No HTTP layer between UI and runtime at all. |
| Python agent runtime | **Swift** | The real work. See below. |

## Decision 1: rewrite the runtime in Swift, don't embed Python

The tempting option is a Swift shell around the existing Python. I'd argue
against it:

- Shipping a Python interpreter inside a signed `.app` means vendoring the
  runtime, code-signing every `.so`, and fighting notarization. It's a
  known-painful path.
- The Python here is ~3,000 lines of orchestration — state machine, tool
  dispatch, policy checks, HTTP calls. It maps almost 1:1 onto Swift
  `async`/`await`. It is not the hard part.
- The genuinely hard parts (hypervisor, model inference, keychain, UI) all
  become *first-party frameworks* in Swift and *FFI problems* in Python.

So: the Python codebase becomes the reference implementation and the test
oracle, not the shipped artifact. Its structure survives — the
`SandboxProvider` protocol, the policy engine, the event-sourced task log, the
evidence model — because those were designed to be portable.

## Decision 2: model inference

Three viable backends, and the `ModelGateway` abstraction means you don't have
to pick permanently:

1. **Native Ollama** (recommended to start). Already Metal-accelerated, has
   tool calling, has a stable HTTP API — the existing `ModelGateway` port is
   nearly a copy. Downside: an external dependency your users must install,
   which is awkward for a shipping app.
2. **MLX / MLXLLM** (recommended end state). Apple's array framework, Swift
   bindings available, models load in-process. No external dependency, so the
   app is genuinely self-contained. Tool calling has to be handled at the
   prompt/grammar level rather than by an API, which is real work.
3. **Foundation Models framework** — Apple's on-device model with Swift-native
   tool calling. If it fits, it's the most native option available and removes
   model management entirely. **[verify]** Check the current capability and
   context limits against what an agent loop needs; my information may be
   stale, and an on-device model with a small context window will struggle
   with long agent traces.

Ship on Ollama, keep the gateway abstraction, migrate to MLX or Foundation
Models when the tool-calling story there is solid.

## Decision 3: one VM, or one per task

Virtualization.framework VMs are heavier than containers — expect seconds to
boot, and a few hundred MB of RAM each, plus a disk image per VM. On a laptop
that argues for:

- **Default: one persistent VM** ("My AI Computer"), started on demand,
  suspended when idle via `saveMachineStateTo`.
- **Opt-in: ephemeral VM** per task, cloned from a golden image with APFS
  copy-on-write (`clonefile`), which makes disk cloning effectively free and
  instant on APFS.

That inverts the Docker default (ephemeral-first), and it's the right
inversion for a single-user laptop.

## Architecture

```
┌─────────────────────────────────────────────┐
│  AgentApp (SwiftUI)                         │
│    TaskListView · TraceView · ApprovalView  │
│    ComputerView  ← VZVirtualMachineView     │
└───────────────┬─────────────────────────────┘
                │ in-process, no HTTP
┌───────────────▼─────────────────────────────┐
│  AgentCore (Swift package)                  │
│    AgentRuntime      task state machine     │
│    ToolRegistry      17 tools               │
│    PolicyEngine      allow/approve/deny     │
│    ModelGateway      Ollama → MLX           │
│    MemoryStore       SQLite + Accelerate    │
│    SecretStore       Keychain               │
│    TaskStore         SQLite via GRDB        │
└───────────────┬─────────────────────────────┘
                │ XPC  (privilege boundary)
┌───────────────▼─────────────────────────────┐
│  SandboxHelper (XPC service)                │
│    holds com.apple.security.virtualization  │
│    VZVirtualMachine lifecycle               │
│    vsock channel to the guest agent         │
└───────────────┬─────────────────────────────┘
                │ vsock
┌───────────────▼─────────────────────────────┐
│  Linux guest (ARM64)                        │
│    guest-agent (exec, files, screenshots)   │
│    Xfce/openbox · Chromium · terminal       │
└─────────────────────────────────────────────┘
```

The privilege split from `docs/SECURITY.md` survives intact and gets
*stronger*: the app process that handles untrusted web content and model
output holds no virtualization entitlement. Only the XPC helper can touch a VM,
and it will only operate on VMs it created.

## Entitlements required

```xml
<key>com.apple.security.virtualization</key><true/>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
```

`com.apple.security.virtualization` is available to any developer account —
**[verify]** whether the "hypervisor" entitlement needed for some
configurations still requires a request to Apple; policy here has changed
before.

## Guest image pipeline

The awkward part, and the equivalent of `build-rootfs.sh`. You need an ARM64
Linux VM with the desktop and the guest agent. Options:

1. **Boot a distro installer ISO once**, install the desktop and guest agent by
   hand, then keep the resulting disk image as the golden image. Simple,
   manual, works.
2. **Build the image on Linux CI** with the existing `sandbox/Dockerfile` as
   the package list, exported to a raw disk image. Reproducible; needs a Linux
   builder.
3. **Fetch a cloud image** (Debian/Ubuntu ARM64 `.qcow2`→raw) and configure it
   on first boot with cloud-init. Least manual work, most moving parts.

Recommend (3) for development, (2) for shipping — a signed app should ship a
known, versioned image, not configure one at install time.

**[unverified]** Whether you ship the image in the app bundle (large, but
self-contained and signed) or download it on first run (smaller app, needs
integrity checking). The bundle will be ~2–4GB with a desktop, so realistically
this is a first-run download with a pinned SHA-256.

## What carries over unchanged

- The `SandboxProvider` protocol — it was designed for exactly this swap.
- The policy engine's rules table, verbatim.
- The evidence model (findings + provenance + confidence + relationships).
- The event-sourced task log, and the budgets/cancel/compaction logic.
- The eval suites — they're JSON, and the runner just needs a new transport.
- Every security decision and its rationale in `docs/SECURITY.md`.

## What gets deleted

noVNC, websockify, x11vnc, Redis, Qdrant, Docker Compose, the FastAPI HTTP
layer, the unix-socket manager protocol, Fernet key management, the host setup's
GID detection. That's a large amount of accidental complexity that existed to
work around not being native.

## Real risks

1. **Tool calling on-device.** Everything hinges on a local model reliably
   emitting tool calls. Ollama makes this easy today; MLX and Foundation
   Models are where it gets uncertain. Don't cut the Ollama path until a
   replacement is proven against the eval suites.
2. **VM boot latency in the UX.** Seconds, not milliseconds. The persistent-VM
   default and suspend/resume are the mitigation; a pre-warmed VM pool is the
   follow-up.
3. **Guest image maintenance.** You now own a Linux distribution image: its
   updates, its CVEs, its size. This is the single biggest ongoing cost of
   going native, and it doesn't show up until month three.
4. **App Sandbox friction.** A sandboxed app writing multi-gigabyte VM images
   and managing network needs its container paths and entitlements right.
   Expect to fight this.
5. **Apple Silicon only.** Virtualization.framework on Intel Macs is far more
   limited. Decide early whether you care.

## Suggested order

1. **Spike the VM first.** A throwaway Swift app that boots a Linux VM, shows
   `VZVirtualMachineView`, and runs one command over vsock. Nothing else
   matters if this doesn't work on your machine, and it's a day of work.
2. Port `ModelGateway` against native Ollama; verify tool calling.
3. Port `TaskStore` + `AgentRuntime` + `PolicyEngine`; run the `files.json`
   eval suite against it.
4. Port memory and secrets.
5. SwiftUI shell around it.
6. Then decide about MLX / Foundation Models, with evals to compare against.

Keep the Python stack runnable throughout. It's your reference implementation,
and being able to diff behaviour against it is worth more than the disk space.
