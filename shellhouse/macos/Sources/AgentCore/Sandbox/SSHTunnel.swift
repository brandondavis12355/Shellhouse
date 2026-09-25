import Foundation

/// Keeps the SSH tunnel to the Linux sandbox host alive for as long as this
/// process runs, and restarts it if it drops (network blip, the host
/// rebooting, someone closing the wrong terminal tab).
///
/// `RemoteSandboxManager` only ever talks to `127.0.0.1:<localManagerPort>`
/// and `127.0.0.1:<novncLocalPort>` — this is what makes those ports real.
/// `sandbox-manager` itself still never listens on the network (see
/// `docs/SECURITY.md`); this tunnel forwards to its Unix socket over SSH,
/// same as running the `ssh -L ...` command by hand, just supervised.
///
/// Requires the SSH key for `user@host` to be usable non-interactively
/// (loaded in `ssh-agent`, or unprotected) — `BatchMode=yes` makes a missing
/// or locked key fail fast with a clear stderr message instead of hanging on
/// a passphrase prompt nothing can answer.
public final class SSHTunnel: @unchecked Sendable {
    public struct Config: Sendable {
        public let host: String
        public let user: String
        public let managerSocketPath: String
        public let localManagerPort: Int
        public let novncLocalPort: Int
        public let novncRemotePort: Int
        /// Per-bot sandboxes each get their own noVNC port, allocated by
        /// `docker_backend.py` from `SANDBOX_PORT_BASE`/`SANDBOX_PORT_COUNT`
        /// (6100-6131 by default). Only `novncLocalPort` (6080, the legacy
        /// shared container) was ever tunneled, so every bot after the first
        /// got a `ComputerPanel` pointed at a local port nothing was
        /// listening on. Forwarding this whole range up front — a fixed,
        /// known range on both ends — sidesteps having to renegotiate the
        /// tunnel's `-L` flags every time a bot is created.
        public let ephemeralPortBase: Int
        public let ephemeralPortCount: Int

        public init(
            host: String,
            user: String,
            managerSocketPath: String,
            localManagerPort: Int = 8765,
            novncLocalPort: Int = 6080,
            novncRemotePort: Int = 6080,
            ephemeralPortBase: Int = 6100,
            ephemeralPortCount: Int = 32
        ) {
            self.host = host
            self.user = user
            self.managerSocketPath = managerSocketPath
            self.localManagerPort = localManagerPort
            self.novncLocalPort = novncLocalPort
            self.novncRemotePort = novncRemotePort
            self.ephemeralPortBase = ephemeralPortBase
            self.ephemeralPortCount = ephemeralPortCount
        }
    }

    private let config: Config
    private let onStderr: (String) -> Void
    private let restartDelay: UInt64 = 5_000_000_000  // 5s, in nanoseconds

    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var restartTask: Task<Void, Never>?

    public init(config: Config, onStderr: @escaping (String) -> Void = { _ in }) {
        self.config = config
        self.onStderr = onStderr
    }

    /// Idempotent: safe to call again if it's already running.
    ///
    /// Also treats an already-listening local port as "running" without
    /// spawning a second `ssh`. Xcode's Stop button doesn't reliably deliver
    /// `applicationWillTerminate`, so a previous run's tunnel can outlive the
    /// app that started it; without this check, every relaunch would spawn a
    /// new `ssh` that immediately fails with "Address already in use" and
    /// then retries forever via `scheduleRestart`.
    public func start() {
        lock.lock()
        stopped = false
        let alreadyRunning = process != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        if isLocalPortOpen(port: config.localManagerPort) && isLocalPortOpen(port: config.novncLocalPort) {
            onStderr("A tunnel is already listening on \(config.localManagerPort)/\(config.novncLocalPort) "
                + "(likely from a previous run) — reusing it instead of starting another.")
            return
        }
        spawn()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let current = process
        process = nil
        lock.unlock()
        restartTask?.cancel()
        current?.terminationHandler = nil
        current?.terminate()
    }

    private func spawn() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "\(config.localManagerPort):\(config.managerSocketPath)",
            "-L", "\(config.novncLocalPort):localhost:\(config.novncRemotePort)",
        ]
        for offset in 0..<config.ephemeralPortCount {
            let port = config.ephemeralPortBase + offset
            task.arguments?.append(contentsOf: ["-L", "\(port):localhost:\(port)"])
        }
        task.arguments?.append("\(config.user)@\(config.host)")

        let errPipe = Pipe()
        task.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [onStderr] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onStderr(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        task.terminationHandler = { [weak self] _ in
            self?.handleExit()
        }

        do {
            try task.run()
            lock.lock()
            process = task
            lock.unlock()
        } catch {
            onStderr("Failed to launch ssh: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func handleExit() {
        lock.lock()
        process = nil
        let shouldRestart = !stopped
        lock.unlock()
        if shouldRestart { scheduleRestart() }
    }

    /// `NSLock.lock()/unlock()` are `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — calling
    /// them directly inside an async function body is a Swift 6 error, so the
    /// locked check is factored into this plain synchronous method instead.
    private func isStillWantedAfterRestartDelay() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    private func scheduleRestart() {
        restartTask = Task { [weak self, restartDelay] in
            try? await Task.sleep(nanoseconds: restartDelay)
            guard let self, !Task.isCancelled else { return }
            if self.isStillWantedAfterRestartDelay() { self.spawn() }
        }
    }
}
