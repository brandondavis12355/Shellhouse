import Foundation
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Credential storage, backed by the macOS Keychain.
///
/// This replaces the Python build's Fernet-encrypted database column, and it's
/// a straight improvement: there is no longer an encryption key sitting in a
/// `.env` file next to the data it protects. The OS holds the key, values are
/// encrypted at rest by the system, and access can optionally require Touch ID
/// per use.
///
/// The invariant from the Python implementation is unchanged and is the whole
/// point of the design:
///
///     the model learns that a credential EXISTS, never what it is
///
/// So there is deliberately **no API here that returns a value to the agent
/// loop**. `resolveForExecution` exists only to hand values to the sandbox
/// provider's `env` parameter, and its result must go straight there.
public actor SecretStore {
    /// Keychain service name; all items are scoped under it.
    private let service: String
    private let requireBiometrics: Bool

    public init(service: String = "ai.compute.agent.secrets", requireBiometrics: Bool = false) {
        self.service = service
        self.requireBiometrics = requireBiometrics
    }

    /// Safe metadata — what the model and the UI are allowed to see.
    public struct SecretInfo: Sendable, Codable, Identifiable {
        public let name: String
        public let notes: String
        /// Short hash of the value, so a rotation can be confirmed without
        /// ever revealing it.
        public let fingerprint: String
        public let modified: Date?

        public var id: String { name }
    }

    public enum SecretError: LocalizedError {
        case invalidName(String)
        case keychain(OSStatus)
        case notFound(String)
        case biometricsFailed

        public var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return """
                Invalid secret name '\(name)'. Use uppercase letters, digits and \
                underscores, starting with a letter (e.g. GITHUB_TOKEN).
                """
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status): \(message ?? "unknown")"
            case .notFound(let name):
                return "No secret named '\(name)'"
            case .biometricsFailed:
                return "Biometric authentication failed or was cancelled"
            }
        }
    }

    /// Environment-variable names only. A crafted name must not be able to
    /// become a shell fragment when exported in the guest.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard let first = name.first, first.isUppercase, first.isLetter else { return false }
        return name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }

    // MARK: - Write

    public func put(name: String, value: String, notes: String = "") throws {
        guard Self.isValidName(name) else { throw SecretError.invalidName(name) }
        guard !value.isEmpty else { throw SecretError.invalidName(name) }

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: "AI Computer — \(name)",
            kSecAttrComment as String: notes,
            // Not synchronized to iCloud, and only available while unlocked.
            // An agent's credentials have no business leaving this machine.
            // ThisDeviceOnly: never restored to another Mac from a backup either.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]

        #if canImport(LocalAuthentication)
        if requireBiometrics {
            // Per-use Touch ID. Worth considering for high-value credentials:
            // it converts "the agent can use my token whenever" into "the
            // agent can use my token when I'm present".
            var accessError: Unmanaged<CFError>?
            if let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &accessError
            ) {
                attributes[kSecAttrAccessControl as String] = access
                attributes.removeValue(forKey: kSecAttrAccessible as String)
            }
        }
        #endif

        // Upsert: delete then add, because SecItemUpdate can't change access
        // control in place.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ] as CFDictionary)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
    }

    // MARK: - Read (metadata only)

    /// Names and metadata. No values. This is what backs the `list_secrets`
    /// tool and the UI.
    public func list() throws -> [SecretInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            // Note: kSecReturnData is NOT set. Listing must never decrypt, so
            // it also never triggers a biometric prompt.
            kSecReturnData as String: false,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw SecretError.keychain(status)
        }

        return items.compactMap { item in
            guard let name = item[kSecAttrAccount as String] as? String else { return nil }
            return SecretInfo(
                name: name,
                notes: item[kSecAttrComment as String] as? String ?? "",
                // Keychain doesn't store our fingerprint, and computing one
                // would require decrypting. The generic-password `creationDate`
                // is enough to tell that a rotation happened.
                fingerprint: "",
                modified: item[kSecAttrModificationDate as String] as? Date
            )
        }
        .sorted { $0.name < $1.name }
    }

    public func delete(name: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ] as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecretError.keychain(status)
        }
    }

    // MARK: - Execution-time resolution

    /// Decrypt the named secrets for injection into a sandbox execution.
    ///
    /// The ONLY function here that returns plaintext. Its return value must be
    /// passed directly to `SandboxProvider.exec(env:)` and nowhere else — not
    /// logged, not returned in a tool result, not placed in a message. The
    /// caller is responsible for masking these values out of command output
    /// before the model sees it (see `mask`).
    /// Resolves ONE named secret's plaintext value for the app's own direct
    /// use — today, an `Authorization` header on an outbound request to a
    /// user-configured remote model provider (see `OpenAICompatibleBackend`).
    /// Deliberately separate from `resolveForExecution`: that one's contract
    /// is "goes straight into a sandbox `env`, nowhere else"; this one's is
    /// "goes straight into a request header the model itself never sees" —
    /// still never logged, returned in a tool result, or placed in any
    /// message a model reads.
    public func resolveOne(name: String) throws -> String? {
        try resolveForExecution(names: [name])[name]
    }

    /// Secrets the app itself uses, which no bot tool may ever receive: the sandbox-manager token (control of
    /// every VM), the friends relay token, and model API keys (a bot's remote key, the fast model's key).
    public static func isAppInternal(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["SANDBOX_MANAGER_TOKEN", "RELAY_REGISTRATION_TOKEN", "RELAY_IDENTITY_KEY_V1", "FAST_MODEL_API_KEY"].contains(upper)
            || upper.hasPrefix("REMOTE_API_KEY_")
    }

    public func resolveForExecution(names: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in names where Self.isValidName(name) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: name,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseOperationPrompt as String:
                    "The agent is using the credential \(name)",
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                continue   // missing or denied; caller reports which were unavailable
            }
            out[name] = value
        }
        return out
    }

    /// Redact secret values from text before it reaches the model or a log.
    ///
    /// A backstop, not the primary control. The primary control is never
    /// putting values where they could leak — but `curl -v` will happily echo
    /// an Authorization header into stderr, and that stderr becomes a tool
    /// result the model reads.
    public nonisolated func mask(_ text: String, values: [String]) -> String {
        var out = text
        for value in values where value.count >= 6 {
            out = out.replacingOccurrences(of: value, with: "[REDACTED]")
            // A tool's own masking ("Token: github_pat_11AB…_****", from `gh auth status`) still shows the
            // start of the value: hide that too.
            if value.count >= 20 {
                out = out.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: String(value.prefix(10))) + #"\S*"#,
                                               with: "[REDACTED]", options: .regularExpression)
            }
        }
        return Self.maskTokenShapes(out)
    }

    /// Known credential shapes, whole or cut short with `*` (GitHub tokens, OpenAI- and Google-style keys),
    /// masked whether or not the value is one this app handed out.
    public nonisolated static func maskTokenShapes(_ text: String) -> String {
        let patterns = [#"github_pat_[A-Za-z0-9_]{6,}\**"#, #"\bgh[pousr]_[A-Za-z0-9]{6,}\**"#,
                        #"\bsk-[A-Za-z0-9_-]{12,}\**"#, #"\bAIza[0-9A-Za-z_-]{12,}\**"#]
        var out = text
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return out
    }
}
