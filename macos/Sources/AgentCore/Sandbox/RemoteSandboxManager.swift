import Foundation

/// `SandboxProvider` backed by the Linux-hosted `sandbox-manager` service
/// (`sandbox-manager/app/main.py`), reached through a local port forwarded
/// over SSH to its Unix socket.
///
/// `sandbox-manager` deliberately never listens on a network socket — see
/// `docs/SECURITY.md` — so `baseURL` here must point at a loopback port kept
/// alive by an SSH tunnel (`ssh -L <port>:/path/to/manager.sock user@host`),
/// never at the Linux host directly. That tunnel is what stands in for
/// `Virtualization.framework`'s in-process VM: the "computer" now lives on
/// another machine, but the privilege boundary the manager enforces is
/// unchanged.
public final class RemoteSandboxManager: SandboxProvider, Sendable {
    public let name = "remote-docker"

    /// Where connection drops and recoveries are reported (the app sends them to the debug console).
    nonisolated(unsafe) public static var connectionLog: (@Sendable (String) -> Void)?
    /// How long a call waits for the tunnel to come back before giving up (the tunnel restarts in ~1 s).
    static let reconnectDelays: [Double] = [0.5, 1, 2, 3, 5, 8]

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: - Transport

    static let safeToRetry: Set<String> = ["v1/read_file", "v1/write_file", "v1/health", "v1/list"]

    /// `timeout`: how long the manager may take to answer. A command's own timeout plus headroom
    /// for exec; otherwise URLSession's 60 s default would fail every command longer than a minute.
    private func call(_ path: String, body: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = max(timeout, 60)
        request.setValue(token, forHTTPHeaderField: "X-Manager-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        // Idempotent calls, and exec (which carries a request_id), are retried while the tunnel reconnects.
        let retryable = Self.safeToRetry.contains(path) || body["request_id"] != nil
        do {
            var attempt = 0
            while true {
                do {
                    (data, response) = try await session.data(for: request)
                    if attempt > 0 { Self.connectionLog?("sandbox-manager reachable again; \(path) went through on retry \(attempt)") }
                    break
                } catch let error as URLError where retryable && Self.isTransient(error) && attempt < Self.reconnectDelays.count {
                    if attempt == 0 { Self.connectionLog?("lost the connection to sandbox-manager during \(path) (\(error.code.rawValue): \(error.localizedDescription)); retrying") }
                    try await Task.sleep(nanoseconds: UInt64(Self.reconnectDelays[attempt] * 1_000_000_000))
                    attempt += 1
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if retryable { Self.connectionLog?("gave up on sandbox-manager for \(path): \(error.localizedDescription)") }
            // The tunnel being down looks like any other network failure to
            // URLSession, so say so rather than leaking a generic POSIX error.
            throw SandboxError.providerError(
                "Could not reach sandbox-manager at \(baseURL). Is the SSH tunnel to "
                + "the Linux host still running? (\(error.localizedDescription))"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw SandboxError.providerError("sandbox-manager returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SandboxError.providerError(
                "sandbox-manager \(path) failed (\(http.statusCode)): \(message)"
            )
        }
        guard !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Errors from a connection that dropped or wasn't there for a moment, as opposed to a bad request.
    static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .timedOut, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
            .contains(error.code)
    }

    private static func handle(from json: [String: Any]) -> SandboxHandle {
        var metadata: [String: String] = [:]
        for key in ["vnc_url", "ip_address", "display", "workspace_host_path"] {
            if let value = json[key] as? String { metadata[key] = value }
        }
        if let inner = json["metadata"] as? [String: Any] {
            for (key, value) in inner { metadata[key] = "\(value)" }
        }
        return SandboxHandle(
            id: json["id"] as? String ?? "",
            provider: json["provider"] as? String ?? "docker",
            persistent: json["persistent"] as? Bool ?? false,
            metadata: metadata
        )
    }

    // MARK: - SandboxProvider

    public func create(taskID: String, persistent: Bool) async throws -> SandboxHandle {
        try await Self.handle(from: call("v1/create", body: ["task_id": taskID, "persistent": persistent]))
    }

    public func start(_ sandboxID: String) async throws -> SandboxHandle {
        try await Self.handle(from: call("v1/start", body: ["sandbox_id": sandboxID]))
    }

    public func exec(
        _ sandboxID: String,
        command: String,
        timeout: TimeInterval,
        env: [String: String]?
    ) async throws -> ExecResult {
        var body: [String: Any] = ["sandbox_id": sandboxID, "command": command, "timeout": Int(timeout)]
        if let env { body["env"] = env }
        // The id makes a retry after a dropped connection safe: the manager runs the command at most once and
        // hands the retry the stored (or still-running) result.
        body["request_id"] = UUID().uuidString
        let json: [String: Any]
        do {
            json = try await call("v1/exec", body: body, timeout: timeout + 30)
        } catch SandboxError.providerError(let message) where message.contains("(422)") && message.contains("request_id") {
            // An older manager that doesn't know request_id yet: run it the old way (no safe retry).
            body["request_id"] = nil
            json = try await call("v1/exec", body: body, timeout: timeout + 30)
        }
        return ExecResult(
            exitCode: Int32(json["exit_code"] as? Int ?? 1),
            stdout: json["stdout"] as? String ?? "",
            stderr: json["stderr"] as? String ?? ""
        )
    }

    public func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data {
        let relative = try safeRelativePath(path)
        var body: [String: Any] = ["sandbox_id": sandboxID, "path": relative]
        // The manager enforces this server-side too (its own cap, applied
        // after decoding), so this isn't just a client-side courtesy — an
        // unsent max_bytes silently fell back to the server's 200_000
        // default with no way to ask for more, which is exactly what broke
        // reading back anything larger than that (e.g. a screenshot).
        if maxBytes > 0 { body["max_bytes"] = maxBytes }
        let json = try await call("v1/read_file", body: body)
        guard let base64 = json["content_b64"] as? String, let data = Data(base64Encoded: base64) else {
            throw SandboxError.notFound(path)
        }
        return maxBytes > 0 ? data.prefix(maxBytes) : data
    }

    public func writeFile(_ sandboxID: String, path: String, contents: Data) async throws {
        let relative = try safeRelativePath(path)
        _ = try await call("v1/write_file", body: [
            "sandbox_id": sandboxID,
            "path": relative,
            "content_b64": contents.base64EncodedString(),
        ])
    }

    public func pause(_ sandboxID: String) async throws {
        _ = try await call("v1/pause", body: ["sandbox_id": sandboxID])
    }

    public func resume(_ sandboxID: String) async throws {
        _ = try await call("v1/resume", body: ["sandbox_id": sandboxID])
    }

    public func destroy(_ sandboxID: String) async throws {
        _ = try await call("v1/destroy", body: ["sandbox_id": sandboxID])
    }

    /// Not part of `SandboxProvider` — `destroy(_:)` above is what that
    /// protocol requires, and its `force: false` default has to stay
    /// implicit there so every existing call site keeps leaving a
    /// persistent (per-bot) sandbox alone. This is the one deliberate
    /// exception: the app's "Delete bot" action (`Bot.destroySandbox`),
    /// which actually needs the container gone — see `docker_backend.py`'s
    /// `DockerBackend.destroy`.
    public func forceDestroy(_ sandboxID: String) async throws {
        _ = try await call("v1/destroy", body: ["sandbox_id": sandboxID, "force": true])
    }

    public func health(_ sandboxID: String) async -> Bool {
        guard let json = try? await call("v1/health", body: ["sandbox_id": sandboxID]) else { return false }
        return json["ok"] as? Bool ?? false
    }

    public func reconcile() async throws -> [SandboxHandle] {
        // The Linux-side manager reconciles orphans against Docker on its own
        // startup (`main.py`'s `startup()` hook); there is nothing for the
        // macOS client to adopt or reap here.
        []
    }

    public func listSandboxes() async throws -> [SandboxHandle] {
        let json = try await call("v1/list")
        guard let sandboxes = json["sandboxes"] as? [[String: Any]] else { return [] }
        return sandboxes.map(Self.handle(from:))
    }
}
