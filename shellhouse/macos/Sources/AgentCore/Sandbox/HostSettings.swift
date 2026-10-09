import Foundation

/// Where the Linux sandbox host is. The address changes with the network
/// you're on (home, office, VPN), so it's a setting instead of a constant:
/// an IPv4 address or a hostname — `linux-host.local` (mDNS) keeps working
/// across networks without retyping.
public struct HostSettings: Codable, Equatable, Sendable {
    public static let defaultHost = ""   // set on first launch in Settings › Linux host
    public static let defaultUser = ""
    public static let maxRecents = 6

    public var host: String
    public var user: String
    /// Most recent first; includes the current one. Offered as quick picks.
    public var recentHosts: [String]
    /// The host's own `hostname`, learned from a successful test, so
    /// `<hostname>.local` can be tried on a new network.
    public var knownHostName: String?

    public init(host: String = HostSettings.defaultHost, user: String = HostSettings.defaultUser,
                recentHosts: [String] = [], knownHostName: String? = nil) {
        self.host = host
        self.user = user
        self.recentHosts = recentHosts
        self.knownHostName = knownHostName
    }

    private static let plainName = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$"#

    /// A bare IPv4 address or hostname, or `nil`. Tolerates a pasted
    /// `ssh://user@host`, `user@host` or a trailing `:22`; anything starting
    /// with `-` (an ssh option), or containing spaces/slashes/shell
    /// characters, is rejected — the value ends up on an `ssh` command line.
    public static func normalizedHost(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ssh://") { text = String(text.dropFirst(6)) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            text = String(text[..<colon])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard text.range(of: plainName, options: .regularExpression) != nil else { return nil }
        return text.lowercased()
    }

    public static func normalizedUser(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: plainName, options: .regularExpression) != nil else { return nil }
        return text
    }

    public var isValid: Bool {
        Self.normalizedHost(from: host) != nil && Self.normalizedUser(from: user) != nil
    }

    /// Where `sandbox-manager` listens on the host (the deploy lives in the
    /// user's home directory).
    public var managerSocketPath: String { "/home/\(user)/shellhouse/sandbox-manager-run/manager.sock" }

    /// Addresses worth trying, in order, when the current one is unreachable:
    /// the current, the recents, then `<knownHostName>.local`.
    public var candidates: [String] {
        var list: [String] = []
        for item in [host] + recentHosts + (knownHostName.map { ["\($0.lowercased()).local"] } ?? []) {
            if let normalized = Self.normalizedHost(from: item), !list.contains(normalized) { list.append(normalized) }
        }
        return list
    }

    /// Switch to `newHost`, remembering it (most recent first, bounded).
    public mutating func use(host newHost: String) {
        guard let normalized = Self.normalizedHost(from: newHost) else { return }
        host = normalized
        recentHosts.removeAll { $0 == normalized }
        recentHosts.insert(normalized, at: 0)
        if recentHosts.count > Self.maxRecents { recentHosts.removeLast(recentHosts.count - Self.maxRecents) }
    }
}

public enum HostSettingsStore {
    private static let key = "linuxHostSettings.v1"

    public static func load() -> HostSettings {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(HostSettings.self, from: data), saved.isValid {
            return saved
        }
        return HostSettings()
    }

    public static func save(_ settings: HostSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
}
