import Foundation

/// A bot's `request_credentials` call, checked: what to ask the user for and why. Secret fields are
/// saved to the Keychain by the app and only their names go back to the model; see `result`.
public struct CredentialRequest: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Identifiable {
        public let name: String
        public let label: String
        public let secret: Bool
        public var id: String { name }
    }

    public let reason: String
    public let fields: [Field]

    public static let maxFields = 5

    /// The request, or the error message to hand back to the model.
    public static func parse(_ arguments: [String: AnyCodable]) -> Result<CredentialRequest, ParseError> {
        let reason = (arguments["reason"]?.asString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return .failure(ParseError("request_credentials needs a 'reason' your user can read")) }
        let raw = (arguments["fields"]?.value as? [Any]) ?? []
        var fields: [Field] = []
        for item in raw {
            let dict = (item as? [String: Any]) ?? ((item as? AnyCodable)?.value as? [String: Any]) ?? [:]
            func value(_ key: String) -> Any? { (dict[key] as? AnyCodable)?.value ?? dict[key] }
            let name = (value("name") as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard SecretStore.isValidName(name) else {
                return .failure(ParseError("field name '\(name)' must look like an env var: capital letters, digits and _, starting with a letter (e.g. SITE_PASSWORD)"))
            }
            guard !fields.contains(where: { $0.name == name }) else { return .failure(ParseError("field '\(name)' is listed twice")) }
            let label = (value("label") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            fields.append(Field(name: name, label: label.isEmpty ? name : String(label.prefix(80)), secret: value("secret") as? Bool ?? true))
        }
        guard !fields.isEmpty else { return .failure(ParseError("request_credentials needs at least one field")) }
        guard fields.count <= maxFields else { return .failure(ParseError("ask for at most \(maxFields) fields at a time")) }
        return .success(CredentialRequest(reason: String(reason.prefix(300)), fields: fields))
    }

    public struct ParseError: Error, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    /// What the model sees after the user answers: secret NAMES only, plus any non-secret values.
    public static func result(saved: [String], kept: [String], missing: [String], plain: [String: String], failed: [String]) -> [String: Any] {
        var out: [String: Any] = ["ok": failed.isEmpty && missing.isEmpty]
        if !saved.isEmpty { out["saved_secrets"] = saved }
        if !kept.isEmpty { out["kept_existing_secrets"] = kept }
        if !missing.isEmpty { out["not_provided"] = missing }
        if !failed.isEmpty { out["could_not_save"] = failed }
        if !plain.isEmpty { out["values"] = plain }
        let usable = saved + kept
        if !usable.isEmpty {
            out["how_to_use"] = "You can't read these values. Use them with run_shell(use_secrets: [\(usable.map { "\"\($0)\"" }.joined(separator: ", "))]) "
                + "as $NAME, or type one into a window with type_secret(name, window)."
        }
        return out
    }
}
