# Xcode setup

Written for Xcode 15/16 on Apple Silicon. The structure is deliberate: an
**Xcode app project** that depends on a **local Swift package**. The package
holds all the logic; the app target exists because only an Xcode target can
carry entitlements, an Info.plist, and a code signature — and this app needs
all three.

```
macos/
├── Package.swift            AgentCore, AgentUI, aic, SandboxHelper
├── Sources/…                all the logic, testable without an app
├── Resources/*.entitlements
└── AICompute.xcodeproj      ← you create this (not in the repo)
```

---

## Option A: skip Xcode for the spike (recommended first)

Before wiring up an app, confirm the package compiles and your Mac can host a
VM at all. This needs no Xcode project:

```bash
cd macos
swift build                  # resolves GRDB, compiles AgentCore
swift test                   # runs the policy + path-safety tests
swift run aic doctor         # checks Virtualization.framework + Ollama
```

`swift run aic doctor` won't be able to *create* a VM — a SwiftPM executable
isn't signed with the virtualization entitlement — but it will tell you whether
the framework reports support and whether Ollama is reachable. Expect
compile errors on the first `swift build`; none of this has been compiled.

Fix those before going further. Debugging Swift syntax inside an Xcode app
target with signing problems layered on top is much worse.

---

## Option B: the Xcode app

### 1. Create the project

- **File → New → Project → macOS → App**
- Product Name: `AICompute`
- Interface: **SwiftUI**, Language: **Swift**, Testing: none (tests live in the package)
- Save it **inside `macos/`**, so the project sits next to `Package.swift`

### 2. Add the local package

- **File → Add Package Dependencies… → Add Local…**
- Select the `macos/` folder (the one containing `Package.swift`)
- When asked which products to add to the `AICompute` target, check
  **`AgentCore`** and **`AgentUI`**

Xcode will resolve GRDB from the network on first add.

> If Xcode refuses to add a local package that lives in the same directory as
> the project, move the `.xcodeproj` one level up (to the repo root) and point
> Add Local at `macos/`. Xcode dislikes a project nested inside its own
> package directory.

### 3. Set the deployment target

Target → **General** → Minimum Deployments → **macOS 14.0**. The package
declares `.macOS(.v14)`; a lower app target produces a confusing resolution
error rather than a clear one.

### 4. Signing

Target → **Signing & Capabilities**:

- **Team:** pick a real team. "Sign to Run Locally" / ad-hoc signing will not
  carry the virtualization entitlement, and the VM will fail to start with an
  unhelpful error. A free personal team is fine for development.
- **Signing Certificate:** Development

### 5. Entitlements

Add **App Sandbox** from **+ Capability**. That creates
`AICompute.entitlements`.

Then open that file and add the virtualization key. In Xcode's plist editor,
add a row with key `com.apple.security.virtualization`, type Boolean, value
YES. Or open it as source and paste:

```xml
<key>com.apple.security.virtualization</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

**[verify]** Recent Xcode versions may list *Virtualization* directly in the
**+ Capability** picker. If it's there, use it instead of hand-editing. I'm not
certain which version introduced it, and Apple's entitlement policy here has
changed before — if signing fails complaining the entitlement isn't permitted
for your profile, that's the thing to look up.

`Resources/AgentApp.entitlements` in the repo is the reference for what the
final set should contain.

### 6. Verify the entitlement actually made it

This catches the most common silent failure — the entitlement present in the
file but not in the signature:

```bash
codesign -d --entitlements - --xml \
  ~/Library/Developer/Xcode/DerivedData/AICompute-*/Build/Products/Debug/AICompute.app \
  | plutil -convert xml1 -o - -
```

`com.apple.security.virtualization` must appear. If it doesn't, the build
settings aren't pointing at your entitlements file
(**Build Settings → Code Signing Entitlements**).

### 7. Wire up a minimal app

Replace the generated `ContentView.swift`:

```swift
import SwiftUI
import AgentCore
import AgentUI
import Virtualization

struct ContentView: View {
    @State private var state: ComputerPanel.State = .noSandbox
    @State private var log = ""

    var body: some View {
        VStack {
            ComputerPanel(state: state)
            HStack {
                Button("Boot VM") { Task { await boot() } }
                Button("uname -a") { Task { await run("uname -a") } }
            }
            Text(log).font(.system(.caption, design: .monospaced))
        }
        .padding()
        .frame(minWidth: 900, minHeight: 700)
    }

    // Keep the sandbox alive across button presses.
    @State private var sandbox: VirtualizationSandbox?
    @State private var handle: SandboxHandle?

    func boot() async {
        let config = VirtualizationSandbox.SandboxConfig(
            baseImagePath: NSString(string: "~/agent-vm/agent-base.img")
                .expandingTildeInPath,
            kernelPath: NSString(string: "~/agent-vm/vmlinuz")
                .expandingTildeInPath,
            initrdPath: NSString(string: "~/agent-vm/initrd.img")
                .expandingTildeInPath,
            stateDirectory: NSString(string: "~/agent-vm/instances")
                .expandingTildeInPath
        )
        let provider = VirtualizationSandbox(config: config)
        sandbox = provider
        state = .booting("spike")
        do {
            let created = try await provider.create(taskID: "spike", persistent: true)
            handle = created
            if let machine = await provider.machine(for: created.id) {
                state = .running(machine)
            }
            log = "booted \(created.id)"
        } catch {
            state = .failed(error.localizedDescription)
            log = error.localizedDescription
        }
    }

    func run(_ command: String) async {
        guard let sandbox, let handle else { return }
        do {
            let result = try await sandbox.exec(handle.id, command: command)
            log = result.stdout + result.stderr
        } catch {
            log = error.localizedDescription
        }
    }
}
```

### 8. Guest image location and the App Sandbox

The example above reads `~/agent-vm/`, which a sandboxed app **cannot** do.
For the spike, the pragmatic move is to **turn App Sandbox off** (remove the
capability) so you're debugging one problem instead of two.

When you turn it back on, pick one:

- Put images in the app's own container
  (`~/Library/Containers/…/Data/agent-vm/`) — no user interaction needed.
- Or have the user pick the folder once via `NSOpenPanel` and keep a
  **security-scoped bookmark**. This is the right answer for a shipping app,
  and it is fiddly enough that it deserves its own pass.

### 9. Running

Product → Run. Expect, in roughly this order: Swift compile errors, then a
signing/entitlement error, then a "guest image not found" error, then a VM
that boots but whose guest agent never answers (because the agent isn't
installed in the image yet).

That sequence is progress. Each error is more specific than the last.

---

## Later: the XPC privilege split

`Sources/SandboxHelper/` is a placeholder. Implementing it means:

- A second Xcode target (**macOS → Application Extension?** no — a plain
  **Command Line Tool** embedded in the app bundle's `Contents/MacOS/`)
- Registered via `SMAppService.daemon(plistName:)` or as a login item
- `NSXPCConnection` between app and helper, with the `SandboxProvider`
  protocol as the exported interface
- `Resources/SandboxHelper.entitlements` on the helper, and
  `com.apple.security.virtualization` **removed from the app**

Until then the app itself holds the virtualization entitlement, which means the
process handling untrusted web content can drive a hypervisor. Fine for a
spike; see `../docs/SECURITY.md` for why it isn't fine as an end state.

---

## Common failures

| Symptom | Cause |
|---|---|
| `VZVirtualMachineConfiguration.isSupported` is false | Entitlement missing from the *signature*, not just the file. Check with `codesign -d`. |
| Crash immediately on any VM method | `VZVirtualMachine` called off its queue. All access must go through `VirtualizationSandbox`'s `vmQueue`. |
| VM boots, `ping()` never succeeds | Guest agent not installed or not enabled in the image; or the guest kernel lacks vsock (`modprobe vsock` inside the guest). |
| Black `ComputerView` | VM running but no graphics device, or the guest hasn't started X yet. Check the serial console log in the state directory. |
| "Couldn't find package product 'AgentUI'" | Deployment target below macOS 14, or the local package wasn't re-resolved. File → Packages → Reset Package Caches. |
| Signing fails on the virtualization entitlement | Ad-hoc / "Sign to Run Locally" signing. Select a real team. |
