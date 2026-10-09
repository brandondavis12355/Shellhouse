import Foundation

/// The app's own SSH identity. The app is sandboxed and must not read the person's personal
/// `~/.ssh` keys, so the tunnel (and every other `ssh` the app runs) authenticates with a key that
/// lives inside the app's own container and is authorized on the host separately.
public struct AppSSHIdentity: Sendable {
    public let directory: URL

    public init(directory: URL = AppSSHIdentity.defaultDirectory) { self.directory = directory }

    public static let shared = AppSSHIdentity()

    /// `Application Support/AICompute/ssh` — inside the sandbox container when sandboxed.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AICompute", isDirectory: true).appendingPathComponent("ssh", isDirectory: true)
    }

    public var privateKeyURL: URL { directory.appendingPathComponent("shellhouse_ed25519") }
    public var publicKeyURL: URL { directory.appendingPathComponent("shellhouse_ed25519.pub") }
    public var knownHostsURL: URL { directory.appendingPathComponent("known_hosts") }

    public enum SetupError: Error, LocalizedError {
        case keygenFailed(String)
        public var errorDescription: String? {
            switch self { case .keygenFailed(let why): return "Couldn't create the app's SSH key: \(why)" }
        }
    }

    /// Creates the key pair on first use (no passphrase: it never leaves the container and only works
    /// for what the host authorizes it for). Returns the public key line.
    @discardableResult
    public func ensureKey() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: privateKeyURL.path) || !fm.fileExists(atPath: publicKeyURL.path) {
            try? fm.removeItem(at: privateKeyURL)
            try? fm.removeItem(at: publicKeyURL)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            task.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "shellhouse-app", "-f", privateKeyURL.path]
            let err = Pipe()
            task.standardError = err
            task.standardOutput = Pipe()
            do { try task.run() } catch { throw SetupError.keygenFailed(error.localizedDescription) }
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(task.terminationStatus)"
                throw SetupError.keygenFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
        guard let key = publicKey() else { throw SetupError.keygenFailed("the public key file is empty") }
        return key
    }

    public func publicKey() -> String? {
        guard let text = try? String(contentsOf: publicKeyURL, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isValidPublicKey(line) ? line : nil
    }

    static func isValidPublicKey(_ line: String) -> Bool {
        line.range(of: #"^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [A-Za-z0-9._@-]+)?$"#, options: .regularExpression) != nil
    }

    /// Options every `ssh` the app runs must carry: only this key, no agent, no user config or
    /// personal known_hosts (the sandbox can't read them), and a host-key store in the container.
    public func clientOptions() -> [String] {
        [
            "-F", "/dev/null",
            "-i", privateKeyURL.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
        ]
    }

    /// One command the person pastes into Terminal (which uses their own SSH access) to authorize the
    /// app's key on the host. Idempotent. nil if the user/host/key don't look plain.
    public static func authorizeCommand(publicKey: String, user: String, host: String) -> String? {
        let plainName = #"^[A-Za-z0-9._][A-Za-z0-9._@-]*$"#
        guard isValidPublicKey(publicKey),
              user.range(of: plainName, options: .regularExpression) != nil,
              host.range(of: plainName, options: .regularExpression) != nil else { return nil }
        return "ssh \(user)@\(host) 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; "
            + "grep -qxF \"\(publicKey)\" ~/.ssh/authorized_keys || echo \"\(publicKey)\" >> ~/.ssh/authorized_keys; echo authorized'"
    }
}
