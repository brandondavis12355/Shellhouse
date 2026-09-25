import Foundation
#if canImport(Virtualization)
import Virtualization

/// The agent's computer, as an Apple Virtualization.framework Linux VM.
///
/// This replaces both the Docker container and the Firecracker microVM. It is
/// the closest native equivalent to Firecracker: a real hypervisor boundary,
/// its own guest kernel, and a deliberately small device model.
///
/// Notable differences from the Firecracker implementation:
///
///  - **No root, no tap devices, no jailer.** Apple's framework needs the
///    `com.apple.security.virtualization` entitlement instead of host
///    privileges. NAT networking is a single object (`VZNATNetworkDeviceAttachment`).
///  - **Exec over vsock, not SSH.** No sshd in the guest, no key injection.
///    This is the design the Firecracker notes recommended; here it's the
///    natural path.
///  - **Disk cloning via APFS `clonefile`.** Copy-on-write at the filesystem
///    level makes an ephemeral VM's disk effectively free and instant, which
///    is what makes per-task VMs viable on a laptop.
///  - **The framebuffer is a native view.** No VNC server, no websockify —
///    `VZVirtualMachineView` renders the guest directly. See ComputerView.
///
/// Threading: `VZVirtualMachine` requires all calls on the same serial queue.
/// This type owns that queue and never lets a `VZVirtualMachine` escape it.
public actor VirtualizationSandbox: SandboxProvider {
    public let name = "virtualization"

    private let config: SandboxConfig
    private var machines: [String: VMRecord] = [:]

    /// Every VZVirtualMachine call must happen here.
    private let vmQueue = DispatchQueue(label: "ai.compute.vm", qos: .userInitiated)

    public struct SandboxConfig: Sendable {
        /// Golden image: a configured ARM64 Linux disk image. Never written to.
        public var baseImagePath: String
        public var kernelPath: String
        public var initrdPath: String?
        /// Where per-VM disks and saved states live.
        public var stateDirectory: String
        public var cpuCount: Int
        public var memorySizeBytes: UInt64
        public var guestVsockPort: UInt32
        public var bootTimeout: TimeInterval
        /// Kernel cmdline. `panic=-1` so a guest panic kills the VM rather
        /// than leaving a wedged instance to reap.
        public var kernelArguments: [String]

        public init(
            baseImagePath: String,
            kernelPath: String,
            initrdPath: String? = nil,
            stateDirectory: String,
            cpuCount: Int = 2,
            memorySizeBytes: UInt64 = 4 * 1024 * 1024 * 1024,
            guestVsockPort: UInt32 = 5555,
            bootTimeout: TimeInterval = 90,
            kernelArguments: [String] = [
                "console=hvc0",
                "root=/dev/vda",
                "rw",
                "panic=-1",
                "quiet",
            ]
        ) {
            self.baseImagePath = baseImagePath
            self.kernelPath = kernelPath
            self.initrdPath = initrdPath
            self.stateDirectory = stateDirectory
            self.cpuCount = cpuCount
            self.memorySizeBytes = memorySizeBytes
            self.guestVsockPort = guestVsockPort
            self.bootTimeout = bootTimeout
            self.kernelArguments = kernelArguments
        }
    }

    private final class VMRecord: @unchecked Sendable {
        let handle: SandboxHandle
        let machine: VZVirtualMachine
        var guest: GuestAgentClient?

        init(handle: SandboxHandle, machine: VZVirtualMachine) {
            self.handle = handle
            self.machine = machine
        }
    }

    public init(config: SandboxConfig) {
        self.config = config
    }

    // MARK: - Host capability

    /// Fail with something actionable rather than a crash deep in the framework.
    public static func checkHostSupport() throws {
        #if arch(arm64)
        if !VZVirtualMachine.isSupported {
            throw SandboxError.unsupportedHost(
                "Virtualization.framework reports no support. Check that the app "
                + "is signed with the com.apple.security.virtualization entitlement."
            )
        }
        #else
        throw SandboxError.unsupportedHost(
            "Apple Silicon is required. Virtualization.framework's Linux guest "
            + "support on Intel Macs is too limited for this."
        )
        #endif
    }

    // MARK: - Lifecycle

    public func create(taskID: String, persistent: Bool) async throws -> SandboxHandle {
        try Self.checkHostSupport()

        let sandboxID = persistent
            ? "persistent"
            : "task-\(taskID.prefix(12))-\(UUID().uuidString.prefix(6))"

        // Reuse an already-running VM for this id (idempotent create).
        if let existing = machines[sandboxID] {
            return existing.handle
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: config.baseImagePath) else {
            throw SandboxError.imageMissing(config.baseImagePath)
        }
        try fm.createDirectory(
            atPath: config.stateDirectory,
            withIntermediateDirectories: true
        )

        let diskPath = "\(config.stateDirectory)/\(sandboxID).img"

        // Persistent VMs keep their disk across runs; ephemeral ones get a
        // fresh copy-on-write clone of the golden image every time.
        if !(persistent && fm.fileExists(atPath: diskPath)) {
            try Self.cloneImage(from: config.baseImagePath, to: diskPath)
        }

        let handle = SandboxHandle(
            id: sandboxID,
            provider: name,
            persistent: persistent,
            diskPath: diskPath,
            guestPort: config.guestVsockPort,
            metadata: [
                "taskID": taskID,
                "cpuCount": "\(config.cpuCount)",
                "memoryMiB": "\(config.memorySizeBytes / 1024 / 1024)",
            ]
        )

        let machine = try await makeMachine(diskPath: diskPath)
        let record = VMRecord(handle: handle, machine: machine)
        machines[sandboxID] = record

        try await withVM(machine) { vm in
            try await vm.start()
        }

        // The VM being "started" only means the kernel is running. Wait for
        // the guest agent to answer before telling anyone it's ready.
        let client = GuestAgentClient(
            machine: machine,
            port: config.guestVsockPort,
            queue: vmQueue
        )
        do {
            try await client.waitUntilReady(timeout: config.bootTimeout)
        } catch {
            machines[sandboxID] = nil
            throw SandboxError.guestUnreachable(sandboxID)
        }
        record.guest = client

        return handle
    }

    /// APFS copy-on-write clone. On APFS this is near-instant and consumes no
    /// extra space until written; the fallback is a plain copy.
    private static func cloneImage(from source: String, to destination: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        let result = source.withCString { src in
            destination.withCString { dst in
                clonefile(src, dst, 0)
            }
        }
        if result != 0 {
            // Not APFS, or cross-volume. Fall back to copying.
            try fm.copyItem(atPath: source, toPath: destination)
        }
    }

    private func makeMachine(diskPath: String) async throws -> VZVirtualMachine {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memorySizeBytes

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: config.kernelPath))
        bootLoader.commandLine = config.kernelArguments.joined(separator: " ")
        if let initrd = config.initrdPath {
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrd)
        }
        configuration.bootLoader = bootLoader

        // Root disk
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: diskPath),
            readOnly: false
        )
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]

        // Networking: NAT out, and nothing in. The guest can reach the
        // internet; nothing can reach the guest.
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        // vsock: the only control channel into the guest.
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Graphics + input, so ComputerView can show the desktop and the user
        // can take over the mouse and keyboard.
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1440, heightInPixels: 900)
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Serial console to a log file, so a guest that fails to boot is
        // debuggable instead of silent.
        if let console = try? Self.makeConsoleLog(
            path: "\(config.stateDirectory)/\(UUID().uuidString).console.log"
        ) {
            configuration.serialPorts = [console]
        }

        configuration.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        try configuration.validate()
        return VZVirtualMachine(configuration: configuration, queue: vmQueue)
    }

    private static func makeConsoleLog(
        path: String
    ) throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: handle
        )
        return port
    }

    public func start(_ sandboxID: String) async throws -> SandboxHandle {
        guard let record = machines[sandboxID] else {
            throw SandboxError.notFound(sandboxID)
        }
        let state = await withVMState(record.machine)
        if state != .running {
            try await withVM(record.machine) { vm in try await vm.start() }
        }
        return record.handle
    }

    // MARK: - Execution

    public func exec(
        _ sandboxID: String,
        command: String,
        timeout: TimeInterval,
        env: [String: String]?
    ) async throws -> ExecResult {
        guard let record = machines[sandboxID], let guest = record.guest else {
            throw SandboxError.notRunning(sandboxID)
        }
        return try await guest.exec(command: command, timeout: timeout, env: env)
    }

    public func readFile(
        _ sandboxID: String,
        path: String,
        maxBytes: Int
    ) async throws -> Data {
        guard let record = machines[sandboxID], let guest = record.guest else {
            throw SandboxError.notRunning(sandboxID)
        }
        return try await guest.readFile(path: try safeRelativePath(path), maxBytes: maxBytes)
    }

    public func writeFile(_ sandboxID: String, path: String, contents: Data) async throws {
        guard let record = machines[sandboxID], let guest = record.guest else {
            throw SandboxError.notRunning(sandboxID)
        }
        try await guest.writeFile(path: try safeRelativePath(path), contents: contents)
    }

    // MARK: - Suspend / resume

    /// Save the whole machine to disk, so a paused long-running task resumes
    /// with its browser tabs and running processes intact — not just its row
    /// in the database.
    public func pause(_ sandboxID: String) async throws {
        guard let record = machines[sandboxID] else {
            throw SandboxError.notFound(sandboxID)
        }
        let statePath = "\(config.stateDirectory)/\(sandboxID).vmstate"
        try await withVM(record.machine) { vm in
            try await vm.pause()
            try await vm.saveMachineStateTo(url: URL(fileURLWithPath: statePath))
        }
    }

    public func resume(_ sandboxID: String) async throws {
        guard let record = machines[sandboxID] else {
            throw SandboxError.notFound(sandboxID)
        }
        try await withVM(record.machine) { vm in try await vm.resume() }
    }

    // MARK: - Teardown

    public func destroy(_ sandboxID: String) async throws {
        guard let record = machines[sandboxID] else { return }

        let state = await withVMState(record.machine)
        if state == .running || state == .paused {
            // stop() is a hard power-off. The guest agent should have been
            // asked to sync first by the caller if data matters.
            try? await withVM(record.machine) { vm in try await vm.stop() }
        }
        machines[sandboxID] = nil

        // Reclaim disk for ephemeral VMs only; a persistent computer keeps its
        // disk between runs by definition.
        if !record.handle.persistent, let diskPath = record.handle.diskPath {
            try? FileManager.default.removeItem(atPath: diskPath)
            try? FileManager.default.removeItem(
                atPath: "\(config.stateDirectory)/\(sandboxID).vmstate"
            )
        }
    }

    public func health(_ sandboxID: String) async -> Bool {
        guard let record = machines[sandboxID] else { return false }
        let state = await withVMState(record.machine)
        guard state == .running else { return false }
        guard let guest = record.guest else { return false }
        return await guest.ping()
    }

    /// Reap disks left by a previous process run. A VM does not survive its
    /// host process here (unlike Firecracker, where the VMM is a separate
    /// process), so there is nothing to adopt — only ephemeral leftovers to
    /// clean up. Persistent disks and saved states are preserved.
    public func reconcile() async throws -> [SandboxHandle] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: config.stateDirectory) else {
            return []
        }
        for entry in entries where entry.hasPrefix("task-") && entry.hasSuffix(".img") {
            try? fm.removeItem(atPath: "\(config.stateDirectory)/\(entry)")
        }
        return []
    }

    public func listSandboxes() async throws -> [SandboxHandle] {
        machines.values.map(\.handle)
    }

    /// The live machine for a sandbox, for `VZVirtualMachineView` to display.
    /// Deliberately the only way the UI reaches a VM object.
    public func machine(for sandboxID: String) -> VZVirtualMachine? {
        machines[sandboxID]?.machine
    }

    // MARK: - Queue discipline

    /// Every VZVirtualMachine method must run on the machine's own queue.
    /// Getting this wrong is an immediate crash, so all access funnels here.
    private func withVM<T: Sendable>(
        _ machine: VZVirtualMachine,
        _ body: @escaping @Sendable (VZVirtualMachine) async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            vmQueue.async {
                Task {
                    do {
                        continuation.resume(returning: try await body(machine))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func withVMState(_ machine: VZVirtualMachine) async -> VZVirtualMachine.State {
        await withCheckedContinuation { continuation in
            vmQueue.async {
                continuation.resume(returning: machine.state)
            }
        }
    }
}
#endif
