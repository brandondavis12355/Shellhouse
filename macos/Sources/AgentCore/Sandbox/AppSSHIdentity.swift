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
        AppData.url("ssh")
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

    // MARK: Host keys

    /// A plain known_hosts line: `host[,host…] key-type base64`.
    public static func isValidKnownHostLine(_ line: String) -> Bool {
        line.range(of: #"^[A-Za-z0-9.:\[\]_-]+(,[A-Za-z0-9.:\[\]_-]+)* (ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,2}$"#,
                   options: .regularExpression) != nil
    }

    private func knownHostLines() -> [String] {
        ((try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func hosts(of line: String) -> [String] {
        line.split(separator: " ").first.map { $0.split(separator: ",").map(String.init) } ?? []
    }

    /// Pins host keys that initial_setup.sh verified: they replace whatever the app had for those hosts, and from
    /// then on only they are accepted (`hostKeyChecking(for:)`). Returns how many were pinned.
    @discardableResult
    public func pin(_ lines: [String]) throws -> Int {
        let valid = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isValidKnownHostLine)
        guard !valid.isEmpty else { return 0 }
        let pinnedHosts = Set(valid.flatMap(Self.hosts))
        let kept = knownHostLines().filter { line in Set(Self.hosts(of: line)).isDisjoint(with: pinnedHosts) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ((kept + valid).joined(separator: "\n") + "\n").write(to: knownHostsURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
        return valid.count
    }

    /// `yes` (only the known key) once the app has a key for `host`; `accept-new` (learn it on first contact) before.
    public func hostKeyChecking(for host: String) -> String {
        knownHostLines().contains { Self.hosts(of: $0).contains(host) } ? "yes" : "accept-new"
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
