import Foundation
import Darwin

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
    /// Optional `ssh -R`: makes a Mac-local service (the model proxy) reachable
    /// from the Linux host, e.g. from containers on the docker bridge.
    ///
    /// Host requirements: sshd must allow a non-loopback remote bind
    /// (`GatewayPorts clientspecified` in sshd_config; without it sshd forces
    /// loopback and containers cannot reach the port). `remoteBindAddress`
    /// must be the docker bridge gateway address ONLY (e.g. `172.17.0.1`),
    /// never `0.0.0.0` or `*` (that would expose the proxy to the LAN).
    /// `arguments(for:)` refuses wildcard/empty bind addresses.
    public struct ReverseForward: Sendable, Equatable {
        public let remoteBindAddress: String
        public let remotePort: Int
        public let localHost: String
        public let localPort: Int

        public init(remoteBindAddress: String, remotePort: Int, localHost: String = "127.0.0.1", localPort: Int) {
            self.remoteBindAddress = remoteBindAddress
            self.remotePort = remotePort
            self.localHost = localHost
            self.localPort = localPort
        }

        /// A bind address must name one specific host: a dotted-quad that is not
        /// the wildcard (`0`, `0.0`, `00.0.0.0`...), or a hostname. Never empty/`*`.
        static func isSpecificAddress(_ address: String) -> Bool {
            let parts = address.split(separator: ".", omittingEmptySubsequences: false)
            let numericLike = parts.allSatisfy { part in
                !part.isEmpty && (part.allSatisfy(\.isNumber) || (part.lowercased().hasPrefix("0x") && part.dropFirst(2).allSatisfy(\.isHexDigit)))
            }
            if numericLike {
                // Numeric forms are interpreted by the resolver in several ways
                // (`0`, `127.1`, octal); accept only canonical dotted quads.
                guard parts.count == 4 else { return false }
                let numbers = parts.compactMap { Int($0) }
                guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }),
                      parts.allSatisfy({ $0 == String(Int($0)!) }) else { return false }
                return numbers != [0, 0, 0, 0]
            }
            return true
        }

        /// The `-R` spec, or nil if any part is unsafe (wildcard bind, bad port, odd characters).
        var spec: String? {
            let plain = #"\A[A-Za-z0-9][A-Za-z0-9.-]*\z"#
            guard remoteBindAddress.range(of: plain, options: .regularExpression) != nil,
                  localHost.range(of: plain, options: .regularExpression) != nil,
                  Self.isSpecificAddress(remoteBindAddress),
                  (1...65535).contains(remotePort), (1...65535).contains(localPort) else { return nil }
            return "\(remoteBindAddress):\(remotePort):\(localHost):\(localPort)"
        }
    }

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
        /// Default empty: the argument list is unchanged from before.
        public let reverseForwards: [ReverseForward]

        public init(
            host: String,
            user: String,
            managerSocketPath: String,
            localManagerPort: Int = 8765,
            novncLocalPort: Int = 6080,
            novncRemotePort: Int = 6080,
            ephemeralPortBase: Int = 6100,
            ephemeralPortCount: Int = 32,
            reverseForwards: [ReverseForward] = []
        ) {
            self.host = host
            self.user = user
            self.managerSocketPath = managerSocketPath
            self.localManagerPort = localManagerPort
            self.novncLocalPort = novncLocalPort
            self.novncRemotePort = novncRemotePort
            self.ephemeralPortBase = ephemeralPortBase
            self.ephemeralPortCount = ephemeralPortCount
            self.reverseForwards = reverseForwards
        }
    }

    private var storedConfig: Config
    private var config: Config { lock.lock(); defer { lock.unlock() }; return storedConfig }
    private let onStderr: (String) -> Void
    /// Explains known failures and rate-limits repeats (the tunnel retries every ~20 s).
    private let diagnostics = DiagnosticsBox()

    private final class DiagnosticsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var state = TunnelDiagnostics()
        func next(_ line: String) -> String? { lock.lock(); defer { lock.unlock() }; return state.lineToShow(line) }
    }
    /// A first restart is quick (a blip shouldn't stall commands); repeated failures back off.
    private let quickRestartDelay: UInt64 = 1_000_000_000
    private let restartDelay: UInt64 = 5_000_000_000  // 5s, in nanoseconds
    /// Drops in a row without the tunnel staying up for 30 s. Each one doubles the wait (5, 10, 20, 40, then 60 s).
    private var failureStreak = 0

    /// How long to wait before the next attempt: a blip after a long uptime is retried at once; a host that keeps
    /// refusing is not hammered every 5 s for as long as the network is down.
    static func restartDelaySeconds(failureStreak: Int, quick: Bool) -> Int {
        if quick { return 1 }
        return min(60, 5 << max(0, min(failureStreak - 1, 4)))
    }
    private var lastStart: Date?

    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var restartTask: Task<Void, Never>?

    public init(config: Config, onStderr: @escaping (String) -> Void = { _ in }) {
        self.storedConfig = config
        self.onStderr = onStderr
    }

    /// Point the tunnel at a different host/user (the Linux host's address
    /// changed with the network): tears the current `ssh` down, waits for its
    /// local ports to free up, then starts a new one. Safe to call repeatedly.
    public func reconfigure(_ newConfig: Config) {
        stop()
        lock.lock()
        storedConfig = newConfig
        lock.unlock()
        Task.detached { [self] in
            // `start()` reuses a tunnel it finds already listening; give the
            // one we just stopped a moment to release its ports first.
            for _ in 0..<30 where isLocalPortOpen(port: newConfig.localManagerPort) || isLocalPortOpen(port: newConfig.novncLocalPort) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            start()
        }
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
            // Our own tunnel from a run that was killed (Xcode's Stop): replace it, so this run's options apply
            // (host-key pinning, a changed host). Anything else listening there is left alone and reused.
            if let stale = Self.recordedTunnelPID(), kill(stale, 0) == 0, kill(stale, SIGTERM) == 0 {
                onStderr("Replacing this app's tunnel from a previous run (pid \(stale)) so the current settings apply.")
                for _ in 0..<30 where isLocalPortOpen(port: config.localManagerPort) {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            } else {
                onStderr("A tunnel is already listening on \(config.localManagerPort)/\(config.novncLocalPort) "
                    + "(likely from a previous run) — reusing it instead of starting another.")
                return
            }
        }
        spawn()
    }

    /// Where the running tunnel's process id is kept, so the next launch can tell its own leftover tunnel apart.
    private static var pidFileURL: URL { AppSSHIdentity.defaultDirectory.appendingPathComponent("tunnel.pid") }

    static func recordTunnelPID(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: pidFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(pid).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    /// The recorded pid, if that process is still an `ssh` (so a reused pid number is never signalled).
    static func recordedTunnelPID() -> Int32? {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == "ssh" else { return nil }
        return pid
    }

    /// Drops the current connection so it re-establishes at once (after the Mac wakes: a dead connection would
    /// otherwise take up to 90 s of missed keep-alives to notice). A no-op if the tunnel isn't running.
    public func reconnectNow() {
        lock.lock()
        let current = process
        let wanted = !stopped
        lastStart = lastStart.map { _ in Date(timeIntervalSinceNow: -60) }   // long-lived: restart quickly, not backed off
        lock.unlock()
        guard wanted else { return }
        if let current { current.terminate() } else { scheduleRestart(quick: true) }
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
        // A user/host starting with "-" would be parsed as an ssh option;
        // refuse anything that isn't a plain hostname/IP and username.
        let plainName = #"^[A-Za-z0-9._][A-Za-z0-9._@-]*$"#
        guard config.user.range(of: plainName, options: .regularExpression) != nil,
              config.host.range(of: plainName, options: .regularExpression) != nil else {
            print("[ssh tunnel] refusing to start: invalid host or user in tunnel config")
            return
        }
        guard let arguments = Self.arguments(for: config) else {
            print("[ssh tunnel] refusing to start: invalid reverse forward in tunnel config")
            return
        }
        // The app authenticates with its own key (see AppSSHIdentity); it never reads ~/.ssh.
        do { try AppSSHIdentity.shared.ensureKey() } catch {
            onStderr("\(error.localizedDescription)")
            scheduleRestart()
            return
        }
        // Strict once the host's key is known (pinned by initial_setup.sh, or learned on first contact).
        let checking = "StrictHostKeyChecking=" + AppSSHIdentity.shared.hostKeyChecking(for: config.host)
        task.arguments = AppSSHIdentity.shared.clientOptions()
            + arguments.map { $0 == "StrictHostKeyChecking=accept-new" ? checking : $0 }

        let errPipe = Pipe()
        task.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [onStderr, diagnostics] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, let show = diagnostics.next(line) else { continue }
                onStderr(show)
            }
        }

        task.terminationHandler = { [weak self] _ in
            self?.handleExit()
        }

        do {
            try task.run()
            Self.recordTunnelPID(task.processIdentifier)
            lock.lock()
            process = task
            lastStart = Date()
            lock.unlock()
        } catch {
            onStderr("Failed to launch ssh: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    /// The full `ssh` argument list. Pure, for tests. Returns nil if a reverse
    /// forward is unsafe. With no reverse forwards the output is identical to
    /// the pre-`-R` argument list.
    static func arguments(for config: Config) -> [String]? {
        var args = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            // Explicit loopback bind: never depend on the ssh client's
            // GatewayPorts default to keep forwards off the network.
            "-L", "127.0.0.1:\(config.localManagerPort):\(config.managerSocketPath)",
            "-L", "127.0.0.1:\(config.novncLocalPort):localhost:\(config.novncRemotePort)",
        ]
        for offset in 0..<config.ephemeralPortCount {
            let port = config.ephemeralPortBase + offset
            args.append(contentsOf: ["-L", "127.0.0.1:\(port):localhost:\(port)"])
        }
        for forward in config.reverseForwards {
            guard let spec = forward.spec else { return nil }
            args.append(contentsOf: ["-R", spec])
        }
        args.append("--")
        args.append("\(config.user)@\(config.host)")
        return args
    }

    private func handleExit() {
        lock.lock()
        let status = process?.terminationStatus
        process = nil
        let shouldRestart = !stopped
        // Up for a while before dropping: a blip, reconnect at once. Dying right after starting: back off.
        let quick = lastStart.map { Date().timeIntervalSince($0) > 30 } ?? false
        failureStreak = quick ? 0 : failureStreak + 1
        let seconds = Self.restartDelaySeconds(failureStreak: failureStreak, quick: quick)
        lock.unlock()
        guard shouldRestart else { return }
        onStderr("tunnel dropped (ssh exit \(status.map(String.init) ?? "?")); reconnecting in \(seconds) s")
        scheduleRestart(seconds: seconds)
    }

    /// `NSLock.lock()/unlock()` are `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — calling
    /// them directly inside an async function body is a Swift 6 error, so the
    /// locked check is factored into this plain synchronous method instead.
    private func isStillWantedAfterRestartDelay() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    private func scheduleRestart(quick: Bool = false, seconds: Int? = nil) {
        let delay = seconds.map { UInt64($0) * 1_000_000_000 } ?? (quick ? quickRestartDelay : restartDelay)
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            if self.isStillWantedAfterRestartDelay() { self.spawn() }
        }
    }
}
