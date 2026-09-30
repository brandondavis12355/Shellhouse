import Foundation

/// What the user types into the Friends settings, plus the rules for turning
/// it into a safe `RelayConfig`. Pure (no UI, no network) so the parsing and
/// validation — the easy places to be sloppy with security — are unit-tested.
public struct RelaySettings: Codable, Equatable, Sendable {
    public static let defaultPort = 8443
    public static let maxDisplayNameLength = 40

    /// As typed: "10.0.0.5", "relay.lan:9000", "https://relay.lan:8443/".
    public var address: String
    /// SHA-256 fingerprint of the relay's certificate, any common format.
    public var fingerprint: String
    public var displayName: String

    public init(address: String = "", fingerprint: String = "", displayName: String = "") {
        self.address = address
        self.fingerprint = fingerprint
        self.displayName = displayName
    }

    /// `https://host:port` — https only (the relay refuses to serve plaintext
    /// by default, and the client refuses it too), default port 8443, any
    /// path/query/credentials in the input dropped.
    public static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let parsed = URLComponents(string: text), parsed.scheme?.lowercased() == "https",
              let host = parsed.host, !host.isEmpty else { return nil }
        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = host
        clean.port = parsed.port ?? defaultPort
        return clean.url
    }

    public static func cleanDisplayName(_ input: String) -> String {
        let stripped = input.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxDisplayNameLength)
            .description
    }

    public var isFingerprintValid: Bool { RelayCertificatePin.normalize(fingerprint).count == 64 }

    /// Human-readable problems that stop us connecting (empty when fine).
    public var problems: [String] {
        var issues: [String] = []
        if Self.normalizedURL(from: address) == nil { issues.append("Enter the relay's address (for example 10.0.0.5 or relay.lan:8443).") }
        if !isFingerprintValid { issues.append("Paste the relay certificate's SHA-256 fingerprint (64 hex characters; colons are fine).") }
        if Self.cleanDisplayName(displayName).isEmpty { issues.append("Choose the name your friends will see.") }
        return issues
    }

    public var isComplete: Bool { problems.isEmpty }

    public func config(registrationToken: String?) throws -> RelayConfig {
        guard let url = Self.normalizedURL(from: address) else {
            throw RelayError.invalidConfig("the relay address isn't valid")
        }
        let token = registrationToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RelayConfig(
            baseURL: url,
            pinnedFingerprint: RelayCertificatePin.normalize(fingerprint),
            registrationToken: (token?.isEmpty == false) ? token : nil
        )
    }
}
