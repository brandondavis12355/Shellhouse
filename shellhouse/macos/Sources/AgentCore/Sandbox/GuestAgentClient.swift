import Foundation
#if canImport(Virtualization)
import Virtualization

/// Host side of the vsock channel to the guest agent.
///
/// Protocol: newline-delimited JSON, one request and one response per
/// connection. A connection per request is slightly wasteful but removes all
/// framing and multiplexing complexity, and vsock connections are cheap.
///
/// Why vsock instead of SSH (which the Firecracker backend uses): no sshd in
/// the guest, no key injection at image-build time, and no dependency on guest
/// networking — so a task that needs no internet can run in a VM with
/// networking fully disabled.
///
/// Trust boundary: the guest is untrusted. It renders attacker-controlled web
/// pages under model control. Every response is treated as data — sizes are
/// capped, JSON is parsed defensively, and nothing in a response is executed.
public final class GuestAgentClient: @unchecked Sendable {
    private let machine: VZVirtualMachine
    private let port: UInt32
    private let queue: DispatchQueue

    private static let maxResponseBytes = 32 * 1024 * 1024

    public init(machine: VZVirtualMachine, port: UInt32, queue: DispatchQueue) {
        self.machine = machine
        self.port = port
        self.queue = queue
    }

    // MARK: - Wire types

    private struct Request: Encodable {
        let op: String
        var command: String?
        var path: String?
        var contentsBase64: String?
        var maxBytes: Int?
        var timeout: Double?
        var env: [String: String]?
    }

    private struct Response: Decodable {
        var ok: Bool?
        var exitCode: Int32?
        var stdout: String?
        var stderr: String?
        var contentsBase64: String?
        var error: String?
    }

    // MARK: - Operations

    public func ping() async -> Bool {
        do {
            let response = try await send(Request(op: "ping"), timeout: 5)
            return response.ok == true
        } catch {
            return false
        }
    }

    /// Poll until the guest agent answers. The VM reporting `.running` only
    /// means the kernel started; the agent comes up seconds later.
    public func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 500_000_000   // 0.5s, backing off to 2s
        while Date() < deadline {
            if await ping() { return }
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 2_000_000_000)
        }
        throw SandboxError.bootTimeout("guest agent did not answer within \(Int(timeout))s")
    }

    public func exec(
        command: String,
        timeout: TimeInterval,
        env: [String: String]?
    ) async throws -> ExecResult {
        // `env` carries secret values (see SecretStore). They travel over
        // vsock to the guest and are exported there — never interpolated into
        // the command string, so they stay out of the guest's process list and
        // out of any log on this side.
        let request = Request(
            op: "exec",
            command: command,
            timeout: timeout,
            env: env
        )
        // Allow the transport a little longer than the command itself, so a
        // command timeout is reported by the guest rather than as a transport
        // failure.
        let response = try await send(request, timeout: timeout + 15)
        if let error = response.error {
            return ExecResult.failure(error)
        }
        return ExecResult(
            exitCode: response.exitCode ?? 1,
            stdout: String((response.stdout ?? "").prefix(20_000)),
            stderr: String((response.stderr ?? "").prefix(20_000))
        )
    }

    public func readFile(path: String, maxBytes: Int) async throws -> Data {
        let response = try await send(
            Request(op: "read_file", path: path, maxBytes: maxBytes),
            timeout: 60
        )
        if let error = response.error {
            throw SandboxError.notFound(error)
        }
        guard let encoded = response.contentsBase64,
              let data = Data(base64Encoded: encoded) else {
            throw SandboxError.notFound(path)
        }
        return data
    }

    public func writeFile(path: String, contents: Data) async throws {
        let response = try await send(
            Request(
                op: "write_file",
                path: path,
                contentsBase64: contents.base64EncodedString()
            ),
            timeout: 120
        )
        if let error = response.error {
            throw SandboxError.notFound(error)
        }
    }

    // MARK: - Transport

    private func send(_ request: Request, timeout: TimeInterval) async throws -> Response {
        let connection = try await connect()
        let fileHandle = FileHandle(fileDescriptor: connection.fileDescriptor, closeOnDealloc: false)
        defer { connection.close() }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)   // newline terminator
        try fileHandle.write(contentsOf: payload)

        let data = try await readResponse(from: fileHandle, timeout: timeout)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func connect() async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(
                        throwing: SandboxError.guestUnreachable("no vsock device on this VM")
                    )
                    return
                }
                device.connect(toPort: port) { result in
                    switch result {
                    case .success(let connection):
                        continuation.resume(returning: connection)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Read until the newline terminator, a size cap, or the timeout.
    ///
    /// The size cap matters: the guest is untrusted, so a compromised or
    /// buggy agent must not be able to exhaust host memory by streaming
    /// forever.
    private func readResponse(
        from handle: FileHandle,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    guard let chunk = try handle.read(upToCount: 64 * 1024),
                          !chunk.isEmpty else {
                        break   // EOF
                    }
                    buffer.append(chunk)
                    if buffer.count > Self.maxResponseBytes {
                        throw SandboxError.guestUnreachable(
                            "guest response exceeded \(Self.maxResponseBytes) bytes"
                        )
                    }
                    if buffer.last == 0x0A { break }
                }
                if buffer.last == 0x0A { buffer.removeLast() }
                return buffer
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SandboxError.guestUnreachable("guest agent timed out")
            }
            guard let result = try await group.next() else {
                throw SandboxError.guestUnreachable("no response")
            }
            group.cancelAll()
            return result
        }
    }
}
#endif
