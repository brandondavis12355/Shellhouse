import CryptoKit
import Foundation

/// This installation's identity on a group relay: an Ed25519 key pair. The
/// private key never leaves the Keychain; the user id is derived from the
/// public key (same rule as `group-relay/app/auth.py`), so it can't be
/// claimed by anyone else.
public struct RelayIdentity: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public init(rawPrivateKey: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    public var rawPrivateKey: Data { privateKey.rawRepresentation }
    public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    /// `"u_" + hex(sha256(raw public key))[:32]`
    public var userID: String {
        let digest = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
        return "u_" + digest.map { String(format: "%02x", $0) }.joined().prefix(32)
    }

    func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        privateKey.publicKey.isValidSignature(signature, for: message)
    }

    func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message)
    }
}

/// Where the private key is kept. The app uses the Keychain-backed
/// implementation; tests use the in-memory one.
public protocol RelayKeyStore: Sendable {
    func load() async throws -> Data?
    func save(_ rawKey: Data) async throws
}

public actor InMemoryRelayKeyStore: RelayKeyStore {
    private var stored: Data?
    public init(_ stored: Data? = nil) { self.stored = stored }
    public func load() async throws -> Data? { stored }
    public func save(_ rawKey: Data) async throws { stored = rawKey }
}

/// Keychain storage via the app's existing `SecretStore`, so the relay key
/// gets the same protection (and the same Keychain service) as every other
/// secret the app keeps.
public struct KeychainRelayKeyStore: RelayKeyStore {
    public static let secretName = "RELAY_IDENTITY_KEY_V1"
    private let secrets: SecretStore
    public init(secrets: SecretStore = SecretStore()) { self.secrets = secrets }

    public func load() async throws -> Data? {
        guard let text = try await secrets.resolveOne(name: Self.secretName) else { return nil }
        return Data(base64Encoded: text)
    }

    public func save(_ rawKey: Data) async throws {
        try await secrets.put(name: Self.secretName, value: rawKey.base64EncodedString(), notes: "Group relay identity (Ed25519 private key)")
    }
}

public enum RelayIdentityStore {
    /// The saved identity, or a freshly generated (and saved) one.
    public static func loadOrCreate(in store: RelayKeyStore) async throws -> RelayIdentity {
        if let raw = try await store.load(), let identity = try? RelayIdentity(rawPrivateKey: raw) {
            return identity
        }
        let identity = RelayIdentity()
        try await store.save(identity.rawPrivateKey)
        return identity
    }
}

/// Builds the exact signing string `group-relay` verifies:
/// `METHOD \n PATH[?QUERY] \n TIMESTAMP \n NONCE \n sha256_hex(BODY)`.
public enum RelayRequestSigner {
    public static func signingString(method: String, pathWithQuery: String, timestamp: String, nonce: String, body: Data) -> Data {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("\(method.uppercased())\n\(pathWithQuery)\n\(timestamp)\n\(nonce)\n\(bodyHash)".utf8)
    }

    public static func headers(
        for identity: RelayIdentity, method: String, pathWithQuery: String, body: Data,
        now: Date = Date(), nonce: String = Self.randomNonce()
    ) throws -> [String: String] {
        let timestamp = String(format: "%.3f", now.timeIntervalSince1970)
        let message = signingString(method: method, pathWithQuery: pathWithQuery, timestamp: timestamp, nonce: nonce, body: body)
        let signature = try identity.sign(message).base64EncodedString()
        return [
            "X-User-Id": identity.userID,
            "X-Timestamp": timestamp,
            "X-Nonce": nonce,
            "X-Signature": signature,
        ]
    }

    /// 24 URL-safe characters (matches the server's `[A-Za-z0-9_-]{8,64}`).
    public static func randomNonce() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<24).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

/// Pins the relay's (self-signed) certificate by SHA-256 fingerprint.
public enum RelayCertificatePin {
    /// Accepts `"AB:CD:…"`, `"abcd…"` or `"sha256 Fingerprint=AB:CD:…"`.
    public static func normalize(_ fingerprint: String) -> String {
        let afterEquals = fingerprint.split(separator: "=").last.map(String.init) ?? fingerprint
        return afterEquals.lowercased().filter { $0.isHexDigit }
    }

    public static func fingerprint(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(der: Data, pinned: String) -> Bool {
        let expected = normalize(pinned)
        return expected.count == 64 && fingerprint(ofDER: der) == expected
    }
}
