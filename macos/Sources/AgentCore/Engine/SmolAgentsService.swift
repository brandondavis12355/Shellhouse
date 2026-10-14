import Foundation

/// App-wide plumbing for the smolagents engine: the shared token-gated model
/// proxy and where sandboxes can reach it (docs/SMOLAGENTS.md). The proxy
/// listens on loopback only; a reverse SSH forward exposes it on the Linux
/// host at `sandboxAddress:proxyPort`, which must be the docker bridge
/// gateway address (never a wildcard) so only sandbox containers can reach it.
public final class SmolAgentsService: @unchecked Sendable {
    public static let shared = SmolAgentsService()

    public struct Config: Codable, Equatable, Sendable {
        /// Docker-bridge gateway address on the Linux host, as the containers see it.
        public var sandboxAddress = ""
        public var proxyPort = 18434
        public var runnerCommand = "shellhouse-agent"
        /// Host (or compose alias) sandboxes use to reach the proxy when that
        /// differs from the reverse-forward bind address, e.g. the egress
        /// proxy's model relay in allowlist mode. Blank = `sandboxAddress`.
        public var sandboxVisibleHost = ""

        public init() {}

        /// A private IPv4 address; anything else (blank, hostnames, 0.0.0.0, public) is rejected.
        public var isConfigured: Bool { Self.isPrivateIPv4(sandboxAddress) && (1024...65535).contains(proxyPort) }
        public var containerBaseURL: String { "http://\(visibleHost):\(proxyPort)/v1" }
        var visibleHost: String {
            let host = sandboxVisibleHost.trimmingCharacters(in: .whitespaces)
            let valid = !host.isEmpty && host.count <= 100
                && host.range(of: #"\A[A-Za-z0-9][A-Za-z0-9.-]*\z"#, options: .regularExpression) != nil
            return valid ? host : sandboxAddress
        }

        public static func isPrivateIPv4(_ s: String) -> Bool {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({ $0.count <= 3 && $0.allSatisfy(\.isNumber) }) else { return false }
            let n = parts.compactMap { Int($0) }
            guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return false }
            if n[0] == 10 { return true }
            if n[0] == 172, (16...31).contains(n[1]) { return true }
            if n[0] == 192, n[1] == 168 { return true }
            return false
        }
    }

    private static let defaultsKey = "smolagents.config.v1"
    public let proxy: ModelProxy

    public init(proxy: ModelProxy = ModelProxy()) { self.proxy = proxy }

    public var config: Config {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
                  let saved = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
            return saved
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
        }
    }

    /// The `-R` forward the SSH tunnel needs, or none if not configured.
    public static func reverseForwards() -> [SSHTunnel.ReverseForward] {
        let config = shared.config
        guard config.isConfigured else { return [] }
        return [SSHTunnel.ReverseForward(remoteBindAddress: config.sandboxAddress, remotePort: config.proxyPort, localPort: config.proxyPort)]
    }

    public enum ServiceError: LocalizedError {
        case notConfigured
        public var errorDescription: String? {
            "The smolagents engine isn't set up yet: enter the sandbox network address in Settings › Agent engine."
        }
    }

    /// Starts the loopback proxy if needed and returns its settings for an engine.
    public func engineSettings() async throws -> SmolAgentsEngine.Settings {
        let config = self.config
        guard config.isConfigured else { throw ServiceError.notConfigured }
        // A port changed in Settings since the proxy started: move it, so it matches the tunnel's forward.
        if let running = proxy.port, running != UInt16(config.proxyPort) { proxy.stop() }
        if proxy.port == nil { _ = try await proxy.start(port: UInt16(config.proxyPort)) }
        return SmolAgentsEngine.Settings(containerBaseURL: config.containerBaseURL, runnerCommand: config.runnerCommand)
    }
}
