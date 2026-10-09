import Foundation

/// Result of running a command inside a sandbox.
public struct ExecResult: Sendable, Codable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public static func failure(_ message: String) -> ExecResult {
        ExecResult(exitCode: 1, stdout: "", stderr: message)
    }
}

/// Everything the rest of the system needs to know about one agent computer.
public struct SandboxHandle: Sendable, Codable, Identifiable {
    public let id: String
    public let provider: String
    public let persistent: Bool
    /// Host path of the VM's disk image (nil for non-VM providers).
    public let diskPath: String?
    /// Guest vsock port the agent listens on.
    public let guestPort: UInt32
    public var metadata: [String: String]

    public init(
        id: String,
        provider: String,
        persistent: Bool,
        diskPath: String? = nil,
        guestPort: UInt32 = 5555,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.persistent = persistent
        self.diskPath = diskPath
        self.guestPort = guestPort
        self.metadata = metadata
    }
}

public enum SandboxError: LocalizedError {
    case notFound(String)
    case notRunning(String)
    case imageMissing(String)
    case bootTimeout(String)
    case guestUnreachable(String)
    case unsupportedHost(String)
    case pathEscapesWorkspace(String)
    /// A provider-level transport/request failure with its own complete,
    /// human-readable message (e.g. `RemoteSandboxManager`'s HTTP errors) —
    /// as opposed to the other cases here, which all wrap a bare identifier
    /// or path into a fixed template. Passed through verbatim rather than
    /// templated, since templating an already-complete message produces
    /// nonsense (this replaced a real bug: HTTP failures were being stuffed
    /// into `.guestUnreachable`, which prints "is running but its guest
    /// agent is not answering on vsock" around whatever string you give it —
    /// backwards for a request that never reached a VM at all).
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Unknown sandbox '\(id)'"
        case .notRunning(let id):
            return "Sandbox '\(id)' is not running"
        case .imageMissing(let path):
            return """
            Guest image not found at \(path). Build or download it first — \
            see docs/MACOS-NATIVE.md, "Guest image pipeline".
            """
        case .bootTimeout(let id):
            return "Sandbox '\(id)' did not finish booting in time"
        case .guestUnreachable(let id):
            return """
            Sandbox '\(id)' is running but its guest agent is not answering on \
            vsock. The VM booted but the agent inside it did not start.
            """
        case .unsupportedHost(let reason):
            return "This Mac cannot run agent sandboxes: \(reason)"
        case .pathEscapesWorkspace(let path):
            return "Path '\(path)' escapes the sandbox workspace"
        case .providerError(let message):
            return message
        }
    }
}

/// The single abstraction that keeps the agent runtime from caring whether its
/// computer is a Virtualization.framework VM, a Docker container on a Linux
/// host, or something else.
///
/// This is a direct port of the Python `SandboxProvider` protocol, kept
/// deliberately identical so behaviour can be diffed against the reference
/// implementation.
public protocol SandboxProvider: Sendable {
    var name: String { get }

    func create(taskID: String, persistent: Bool) async throws -> SandboxHandle
    func start(_ sandboxID: String) async throws -> SandboxHandle
    func exec(
        _ sandboxID: String,
        command: String,
        timeout: TimeInterval,
        env: [String: String]?
    ) async throws -> ExecResult
    func readFile(_ sandboxID: String, path: String, maxBytes: Int) async throws -> Data
    func writeFile(_ sandboxID: String, path: String, contents: Data) async throws
    /// Suspends and persists VM state, so a long task resumes with its browser
    /// tabs and running processes intact.
    func pause(_ sandboxID: String) async throws
    func resume(_ sandboxID: String) async throws
    func destroy(_ sandboxID: String) async throws
    func health(_ sandboxID: String) async -> Bool
    /// Adopt or reap sandboxes left behind by a previous run of the host process.
    func reconcile() async throws -> [SandboxHandle]
    func listSandboxes() async throws -> [SandboxHandle]
}

public extension SandboxProvider {
    /// Convenience with the defaults the tools use.
    func exec(_ sandboxID: String, command: String) async throws -> ExecResult {
        try await exec(sandboxID, command: command, timeout: 120, env: nil)
    }

    /// Normalize a path to be relative to the guest's /workspace, rejecting
    /// traversal. Same rule as the Python `_safe_rel`.
    ///
    /// Also strips a leading `workspace/` segment (in addition to a leading
    /// `/`), so `/workspace/notes.txt`, `workspace/notes.txt`, and
    /// `notes.txt` all normalize to the same `notes.txt` — the sandbox
    /// manager already runs relative to /workspace, so a caller-supplied
    /// `/workspace/...` prefix would otherwise double up server-side and
    /// silently look in the wrong place. The system prompt tells the model
    /// its working directory *is* /workspace, so it including that prefix
    /// isn't a misuse to reject — it's the expected way someone would
    /// reasonably write the path.
    func safeRelativePath(_ path: String) throws -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Walk the RAW components first: `standardizingPath` on "/../x" quietly
        // clamps it to "/x", which would turn an escape attempt into a
        // different, valid-looking path instead of rejecting it.
        var depth = 0
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." { depth -= 1; if depth < 0 { throw SandboxError.pathEscapesWorkspace(path) } }
            else if component != "." { depth += 1 }
        }
        let normalized = ("/" + trimmed) as NSString
        var standardized = normalized.standardizingPath
        if standardized.split(separator: "/").contains("..") {
            throw SandboxError.pathEscapesWorkspace(path)
        }
        if standardized.hasPrefix("/") {
            standardized = String(standardized.dropFirst())
        }
        if standardized == "workspace" {
            standardized = ""
        } else if standardized.hasPrefix("workspace/") {
            standardized = String(standardized.dropFirst("workspace/".count))
        }
        return standardized
    }
}
