# macOS-native build

A Swift app that runs the whole stack natively: no Docker, no Homebrew, no
Python at runtime. Apple Silicon, macOS 14+.

Architecture, decisions, and risks: **`../docs/MACOS-NATIVE.md`**.
Project setup: **`XCODE-SETUP.md`**.

## Status

This is a skeleton, and unlike the Python build it has **not even been
compiled** — it was written on a Linux machine with no Swift toolchain. Treat
every file as a reviewed design sketch, not working code.

| Component | File | State |
|---|---|---|
| Sandbox protocol | `Sources/AgentCore/Sandbox/SandboxProvider.swift` | Ported from Python, complete |
| VM provider | `Sources/AgentCore/Sandbox/VirtualizationSandbox.swift` | Written, unbuilt — the critical unknown |
| Guest channel | `Sources/AgentCore/Sandbox/GuestAgentClient.swift` | Written, unbuilt |
| Guest agent | `guest-agent/guest-agent.py` | Written, parses (Python, runs in the VM) |
| Model gateway | `Sources/AgentCore/Model/ModelGateway.swift` | Ollama backend written; MLX deliberately unimplemented |
| Memory | `Sources/AgentCore/Memory/{MemoryStore,Evidence}.swift` | Written, unbuilt |
| Secrets | `Sources/AgentCore/SecretStore.swift` | Written, unbuilt |
| Policy | `Sources/AgentCore/PolicyEngine.swift` | Ported verbatim from Python |
| Computer view | `Sources/AgentApp/ComputerView.swift` | Written, unbuilt |
| **Agent runtime** | — | **Not ported yet.** The state machine, budgets, compaction, and tool dispatch still live only in Python. |
| Task store | — | Not written. GRDB migrations needed. |
| Tool registry | — | Not written. 17 tools to port. |
| XPC helper | `Sources/SandboxHelper/` | Placeholder that compiles; not implemented |
| SwiftUI shell | `Sources/AgentApp/` (target `AgentUI`) | Only ComputerView exists |
| CLI | `Sources/AgentCLI/` | `aic doctor` written; other commands stubbed |
| Tests | `Tests/AgentCoreTests/` | Policy + path-safety tests written |

## Before anything else

```bash
cd macos
swift build          # expect compile errors - none of this has been compiled
swift test           # policy + path-safety tests
swift run aic doctor # host support + Ollama check
```

Get `swift build` clean before opening Xcode. Debugging Swift syntax with
code-signing problems layered on top is significantly worse.

## Do this first: the VM spike

Nothing else matters if a Linux VM won't boot and answer on vsock on your
machine. That is one day of work and it de-risks the entire project. Build
*only* this:

1. A throwaway SwiftUI app with the `com.apple.security.virtualization`
   entitlement.
2. `VirtualizationSandbox.create(taskID:persistent:)` against a Debian ARM64
   image.
3. `ComputerView` showing the guest desktop.
4. One `exec("uname -a")` over vsock returning a result.

If that works, the rest is porting. If it doesn't, you'll know before writing
an agent runtime in a second language.

### Guest image

You need an ARM64 Linux disk image with a desktop and the guest agent. Fastest
path for the spike:

```bash
# A Debian ARM64 cloud image, converted to raw for Virtualization.framework.
# (qemu-img via Homebrew is fine for a one-off — it isn't a runtime dependency.)
qemu-img convert -f qcow2 -O raw debian-arm64.qcow2 agent-base.img
qemu-img resize -f raw agent-base.img 20G
```

Then boot it once, and inside the guest install:

- `xfce4` or `openbox` + `chromium` + `xfce4-terminal` + `thunar` (the same
  package list as `../sandbox/Dockerfile`)
- `xdotool`, `wmctrl`, `scrot` (the computer-use tools depend on these)
- `guest-agent/guest-agent.py` as a systemd unit (install notes are at the
  bottom of that file)

Keep the result as your golden image; `create()` clones it per VM with APFS
`clonefile`, which is instant and costs no extra disk until written.

You also need a kernel and (usually) an initrd extracted from the guest, since
`VZLinuxBootLoader` boots a kernel directly rather than the disk's bootloader.
Copy `/boot/vmlinuz-*` and `/boot/initrd.img-*` out of the image.

**[unverified]** Whether the distro's stock kernel has `CONFIG_VSOCKETS` and
`CONFIG_VIRTIO_VSOCKETS` enabled. Debian's does as modules; confirm with
`modprobe vsock` inside the guest before assuming the agent can be reached.

## Running the model

```bash
brew install ollama          # or the .dmg
ollama serve
ollama pull qwen2.5:7b-instruct
ollama pull nomic-embed-text
```

Native Ollama is Metal-accelerated, which is the whole reason not to keep it
in a container on a Mac.

## Porting order

The Python build is the reference implementation and the test oracle. Port in
this order, checking each step against it:

1. `TaskStore` (GRDB + migrations) — the Python build has no migrations, so
   this is a chance to fix that properly rather than inherit the gap.
2. `AgentRuntime` — the state machine, budgets, cancel, compaction. This is the
   largest single piece: ~500 lines of Python.
3. `ToolRegistry` + the 17 tools.
4. Wire `SecretStore` and `MemoryStore` in.
5. SwiftUI shell: task list, trace, approvals, computer panel.
6. XPC split: move `VirtualizationSandbox` behind `SMAppService` so the app
   process drops its virtualization entitlement.

Step 6 is easy to defer and important not to skip — it's the privilege
boundary from `../docs/SECURITY.md`. Doing it last is fine; doing it never
means the component handling untrusted web content can drive a hypervisor.

## Reusing the eval suites

`../evals/suites/*.json` are transport-agnostic. The runner talks HTTP to the
Python API; for the Swift build, point the `aic` CLI target at the same suite
files and score them the same way. Keeping the suites identical is what lets
you answer "is the Swift port as good as the Python one" with a number instead
of an impression.
