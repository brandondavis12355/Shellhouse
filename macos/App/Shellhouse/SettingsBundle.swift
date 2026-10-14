import AgentCore
import AppKit
import Foundation

/// Every setting the app has, as one XML property list (`.shellhousesettings`): app-wide settings, each bot's
/// settings, each group's settings, and (only when asked for) the secrets. Conversations, memories, tasks and
/// files are not settings and are never included.
///
/// Importing merges: listed keys are set, bots and groups are matched by id, then by name, and created when
/// missing; anything the file doesn't mention is left as it is.
enum SettingsBundle {
    static let format = "shellhouse-settings"
    static let version = 1
    static let fileExtension = "shellhousesettings"

    /// App-wide UserDefaults keys that are settings (not window state or caches).
    static var appKeys: [String] {
        [
            "appearanceMode", "debugModeEnabled", "defaultMaxTokens", "defaultMaxIterations",
            "guardrails.autoReview", GuardrailConfig.yoloKey, GuardrailConfig.trustedGitHubOwnersKey,
            GuardrailConfig.autoAllowReadOnlyShellKey,
            ModelTiers.fastModelKey, ModelTiers.fastProviderKey, ModelTiers.fastRemoteBaseURLKey, ModelTiers.fastRemoteModelKey,
            ModelTiers.embeddingModelKey, OllamaBackend.contextWindowKey, ModelScheduler.slotsKey,
            "ai.compute.agent.runShellAlwaysAllow", "ai.compute.agent.runShellAllowAllBots",
        ] + Reliability.Feature.allCases.map { "reliability.\($0.rawValue)" } + Array(jsonBlobKeys)
    }

    /// Settings stored as a JSON blob in UserDefaults; written out as readable dictionaries.
    static let jsonBlobKeys: Set<String> = ["linuxHostSettings.v1", "relaySettings.v1", "smolagents.config.v1"]

    /// Secrets the app itself owns; `REMOTE_API_KEY_…` (per-bot model keys) are matched by prefix.
    static let appSecretNames: Set<String> = ["SANDBOX_MANAGER_TOKEN", ModelTiers.fastRemoteAPIKeySecretName, "RELAY_REGISTRATION_TOKEN"]

    struct Contents {
        var app: [String: Any] = [:]
        var bots: [BotConfig] = []
        var groups: [GroupChat] = []
        var secrets: [String: String] = [:]

        var summary: String {
            var parts: [String] = []
            if !app.isEmpty { parts.append("\(app.count) app setting\(app.count == 1 ? "" : "s")") }
            if !bots.isEmpty { parts.append("\(bots.count) bot\(bots.count == 1 ? "" : "s")") }
            if !groups.isEmpty { parts.append("\(groups.count) group\(groups.count == 1 ? "" : "s")") }
            if !secrets.isEmpty { parts.append("\(secrets.count) secret\(secrets.count == 1 ? "" : "s")") }
            return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
        }

        /// The Linux host this file would point the app at, if it sets one.
        var host: String? {
            ((app["linuxHostSettings.v1"] as? [String: Any])?["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    enum BundleError: LocalizedError {
        case notSettings, tooNew(Int), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notSettings: return "That file isn't a Shellhouse settings file."
            case .tooNew(let v): return "That settings file is from a newer version of Shellhouse (format \(v))."
            case .unreadable(let why): return "Couldn't read the settings file: \(why)"
            }
        }
    }

    // MARK: Export

    static func export(bots: [BotConfig], groups: [GroupChat], includeSecrets: Bool) async -> Data? {
        var root: [String: Any] = ["format": format, "version": version, "exportedAt": Date()]
        var app: [String: Any] = [:]
        let defaults = UserDefaults.standard
        for key in appKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            if jsonBlobKeys.contains(key), let data = value as? Data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                app[key] = plistSafe(object)
            } else if let safe = plistSafe(value) {
                app[key] = safe
            }
        }
        root["app"] = app
        root["bots"] = bots.compactMap { encodeToPlist($0) }
        root["groups"] = groups.compactMap { encodeToPlist($0) }
        if includeSecrets {
            var secrets: [String: String] = [:]
            let store = SecretStore()
            let names = ((try? await store.list()) ?? []).map(\.name)
            if let values = try? await store.resolveForExecution(names: names) { secrets = values }
            if !secrets.isEmpty { root["secrets"] = secrets }
        }
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    // MARK: Import

    static func parse(_ data: Data) throws -> Contents {
        guard data.count < 4_000_000 else { throw BundleError.unreadable("it's too large") }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw BundleError.unreadable(error.localizedDescription) }
        guard let root = object as? [String: Any], root["format"] as? String == format else { throw BundleError.notSettings }
        let fileVersion = root["version"] as? Int ?? 1
        guard fileVersion <= version else { throw BundleError.tooNew(fileVersion) }

        var contents = Contents()
        let allowed = Set(appKeys)
        for (key, value) in (root["app"] as? [String: Any]) ?? [:] where allowed.contains(key) {
            contents.app[key] = value
        }
        contents.bots = ((root["bots"] as? [Any]) ?? []).compactMap { decodeFromPlist($0, as: BotConfig.self) }
        contents.groups = ((root["groups"] as? [Any]) ?? []).compactMap { decodeFromPlist($0, as: GroupChat.self) }
        for (name, value) in (root["secrets"] as? [String: Any]) ?? [:] {
            guard let text = value as? String, !text.isEmpty, SecretStore.isValidName(name) else { continue }
            contents.secrets[name] = text
        }
        return contents
    }

    /// Writes the app-wide part of `contents` to UserDefaults. Bots, groups and secrets are applied by the caller,
    /// which owns them.
    @MainActor static func applyAppSettings(_ contents: Contents) {
        let defaults = UserDefaults.standard
        for (key, value) in contents.app {
            if jsonBlobKeys.contains(key) {
                guard let object = value as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: jsonSafe(object)) else { continue }
                defaults.set(data, forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
        if let debug = contents.app["debugModeEnabled"] as? Bool { DebugSettings.shared.isEnabled = debug }
    }

    // MARK: Files opened from outside (Finder, `open`, initial_setup.sh)

    /// Whether macOS marks the file as downloaded (mail, browser, AirDrop): then the user confirms before importing.
    static func isQuarantined(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        }
    }

    /// After importing a file someone handed the app, it is overwritten with a short receipt and no secrets, so
    /// they don't stay on disk (and `initial_setup.sh` can see the import happened).
    static func writeReceipt(to url: URL, summary: String) {
        let receipt: [String: Any] = ["format": format + "-receipt", "imported": true, "importedAt": Date(), "summary": summary]
        if let data = try? PropertyListSerialization.data(fromPropertyList: receipt, format: .xml, options: 0) {
            try? data.write(to: url)
        }
    }

    // MARK: Plist ↔ Codable

    private static func encodeToPlist<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return plistSafe(object)
    }

    private static func decodeFromPlist<T: Decodable>(_ object: Any, as type: T.Type) -> T? {
        guard JSONSerialization.isValidJSONObject(jsonSafe(object)),
              let data = try? JSONSerialization.data(withJSONObject: jsonSafe(object)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Property lists have no null and no mixed number types: drop nulls, keep the rest.
    private static func plistSafe(_ value: Any) -> Any? {
        switch value {
        case is NSNull: return nil
        case let dict as [String: Any]: return dict.compactMapValues { plistSafe($0) }
        case let array as [Any]: return array.compactMap { plistSafe($0) }
        default: return value
        }
    }

    /// Dates (which JSON can't hold) become ISO strings on the way back.
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues { jsonSafe($0) }
        case let array as [Any]: return array.map { jsonSafe($0) }
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let data as Data: return data.base64EncodedString()
        default: return value
        }
    }
}

/// Settings files and `shellhouse://` links handed to the app from outside, waiting for `ContentView` (which owns
/// the bots and groups) to apply them.
@MainActor
@Observable
final class ExternalRequests {
    static let shared = ExternalRequests()
    var pendingSettingsFiles: [URL] = []

    /// `shellhouse://ssh-public-key`: copies the app's own SSH public key to the clipboard, for `initial_setup.sh` to
    /// authorize on the Linux host. Only the public half ever leaves the app.
    func handle(_ url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == SettingsBundle.fileExtension { pendingSettingsFiles.append(url) }
            return
        }
        guard url.scheme?.lowercased() == "shellhouse" else { return }
        switch url.host?.lowercased() {
        case "ssh-public-key":
            guard let key = try? AppSSHIdentity.shared.ensureKey() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        default:
            break
        }
    }
}
