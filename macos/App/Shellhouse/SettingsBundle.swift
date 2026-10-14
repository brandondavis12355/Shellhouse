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
        /// What in the file doesn't fit this version, and what happens to it instead. Shown before importing.
        var issues: [Issue] = []

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

    /// One thing in a file that doesn't fit this version.
    struct Issue: Identifiable, Equatable {
        enum Kind { case skipped, filled, note }
        let id = UUID()
        let kind: Kind
        let text: String
        static func skipped(_ text: String) -> Issue { Issue(kind: .skipped, text: text) }
        static func filled(_ text: String) -> Issue { Issue(kind: .filled, text: text) }
        static func note(_ text: String) -> Issue { Issue(kind: .note, text: text) }
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

    /// Reads a settings file, keeping whatever fits this version of the app. Anything that doesn't (a setting this
    /// version doesn't have, a value out of range, a bot or group missing fields, skills or members that no longer
    /// exist) is filled from the defaults or left out, and described in `issues` so the user can decide first.
    static func parse(_ data: Data) throws -> Contents {
        guard data.count < 4_000_000 else { throw BundleError.unreadable("it's too large") }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw BundleError.unreadable(error.localizedDescription) }
        guard let root = object as? [String: Any], root["format"] as? String == format else { throw BundleError.notSettings }

        var contents = Contents()
        let fileVersion = root["version"] as? Int ?? 1
        if fileVersion > version {
            contents.issues.append(.note("The file was made by a newer version of Shellhouse (format \(fileVersion)); settings this version doesn't know are skipped."))
        }

        // App settings.
        let allowed = Set(appKeys)
        for (key, value) in ((root["app"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard allowed.contains(key) else {
                contents.issues.append(.skipped("“\(key)” isn't a setting in this version: skipped."))
                continue
            }
            if let problem = appValueProblem(key: key, value: value) {
                contents.issues.append(.skipped(problem))
                continue
            }
            if jsonBlobKeys.contains(key) {
                guard let blob = completedBlob(key: key, value: value, issues: &contents.issues) else { continue }
                contents.app[key] = blob
            } else {
                contents.app[key] = value
            }
        }

        // Bots: missing fields come from a new bot's defaults; skills this version doesn't ship are left off.
        let knownSkills = Set(SkillLibrary.loadAll().map(\.id))
        let botFields = Set(Mirror(reflecting: defaultBotConfig(name: "", id: "")).children.compactMap(\.label))
        for (index, item) in ((root["bots"] as? [Any]) ?? []).enumerated() {
            guard let dict = item as? [String: Any] else { contents.issues.append(.skipped("Bot \(index + 1) isn't readable: skipped.")); continue }
            let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Bot \(index + 1)"
            let unknown = dict.keys.filter { !botFields.contains($0) }.sorted()
            if !unknown.isEmpty { contents.issues.append(.skipped("\(name): \(list(unknown)) \(unknown.count == 1 ? "isn't a bot setting" : "aren't bot settings") in this version: skipped.")) }
            let defaults = encodeToPlist(defaultBotConfig(name: name, id: (dict["id"] as? String) ?? UUID().uuidString)) as? [String: Any] ?? [:]
            let missing = defaults.keys.filter { dict[$0] == nil && ["id", "name", "colorHex", "avatarStyle", "tagline", "group", "systemPromptText", "selectedSkillIDs", "selectedModel", "modelHasVision", "maxTokensText", "maxIterationsText"].contains($0) }.sorted()
            guard var config = decodeFromPlist(defaults.merging(dict.filter { botFields.contains($0.key) }) { _, imported in imported }, as: BotConfig.self) else {
                contents.issues.append(.skipped("\(name): its settings don't match this version and couldn't be filled in: skipped."))
                continue
            }
            if !missing.isEmpty { contents.issues.append(.filled("\(name): \(list(missing)) missing, so \(missing.count == 1 ? "it uses" : "they use") the default.")) }
            let gone = config.selectedSkillIDs.subtracting(knownSkills).sorted()
            if !gone.isEmpty {
                contents.issues.append(.skipped("\(name): skill\(gone.count == 1 ? "" : "s") \(list(gone)) \(gone.count == 1 ? "isn't" : "aren't") in this version: left off."))
                config.selectedSkillIDs.subtract(gone)
            }
            contents.bots.append(config)
        }

        // Groups: members are bots in this file or already in the app; the app drops the rest when applying.
        for (index, item) in ((root["groups"] as? [Any]) ?? []).enumerated() {
            guard var dict = item as? [String: Any] else { contents.issues.append(.skipped("Group \(index + 1) isn't readable: skipped.")); continue }
            let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Group \(index + 1)"
            dict["name"] = name
            if dict["id"] == nil { dict["id"] = UUID().uuidString }
            if dict["memberBotIDs"] == nil { dict["memberBotIDs"] = [String](); contents.issues.append(.filled("\(name): no member list, so it starts empty.")) }
            guard let group = decodeFromPlist(dict, as: GroupChat.self) else {
                contents.issues.append(.skipped("\(name): its settings don't match this version: skipped."))
                continue
            }
            contents.groups.append(group)
        }

        for (name, value) in (root["secrets"] as? [String: Any]) ?? [:] {
            guard let text = value as? String, !text.isEmpty, SecretStore.isValidName(name) else {
                contents.issues.append(.skipped("Secret “\(name)” isn't usable here: skipped."))
                continue
            }
            contents.secrets[name] = text
        }
        return contents
    }

    /// Members of imported groups that are neither in the file nor in the app (checked once the app's bots are known).
    static func missingMembers(_ contents: Contents, existingBotIDs: Set<String>, existingNames: Set<String>) -> [Issue] {
        let inFile = Set(contents.bots.map(\.id))
        let fileNames = Set(contents.bots.map { $0.name.lowercased() })
        var out: [Issue] = []
        for group in contents.groups {
            let missing = group.memberBotIDs.filter { !inFile.contains($0) && !existingBotIDs.contains($0) }
            if !missing.isEmpty, !(fileNames.isEmpty && existingNames.isEmpty) {
                out.append(.skipped("\(group.name): \(missing.count) member\(missing.count == 1 ? "" : "s") \(missing.count == 1 ? "isn't" : "aren't") in the file or this app: left out."))
            }
        }
        return out
    }

    private static func list(_ items: [String]) -> String {
        items.count <= 3 ? items.joined(separator: ", ") : items.prefix(3).joined(separator: ", ") + " and \(items.count - 3) more"
    }

    /// A value this version can't use for that setting.
    private static func appValueProblem(key: String, value: Any) -> String? {
        if jsonBlobKeys.contains(key) { return value is [String: Any] ? nil : "“\(key)” isn't in the expected form: skipped." }
        switch key {
        case OllamaBackend.contextWindowKey:
            guard let n = value as? Int, OllamaBackend.contextWindowChoices.contains(n) else {
                return "Context window \(value) isn't one this version offers (\(OllamaBackend.contextWindowChoices.map { "\($0 / 1024)k" }.joined(separator: ", "))): kept your current one."
            }
        case ModelScheduler.slotsKey:
            guard let n = value as? Int, ModelScheduler.slotChoices.contains(n) else {
                return "Model sharing \(value) isn't a choice in this version: kept your current one."
            }
        case "appearanceMode":
            guard let mode = value as? String, ["system", "light", "dark"].contains(mode) else { return "Appearance “\(value)” isn't known here: kept yours." }
        case "ai.compute.agent.runShellAlwaysAllow", "ai.compute.agent.runShellAllowAllBots":
            guard value is [Any] else { return "“\(key)” isn't in the expected form: skipped." }
        default:
            if key.hasPrefix("reliability.") || key.hasPrefix("guardrails.") && key != GuardrailConfig.trustedGitHubOwnersKey || key == "debugModeEnabled" {
                guard value is Bool || value is NSNumber else { return "“\(key)” should be on or off: skipped." }
            }
        }
        return nil
    }

    /// The JSON-blob settings (host, relay, smolagents), with fields this version needs and the file lacks taken
    /// from what's set now; nil if it still doesn't fit.
    private static func completedBlob(key: String, value: Any, issues: inout [Issue]) -> [String: Any]? {
        guard let imported = value as? [String: Any] else { return nil }
        let current = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let merged = current.merging(imported) { _, new in new }
        let fits: Bool
        switch key {
        case "linuxHostSettings.v1": fits = decodeFromPlist(merged, as: HostSettings.self) != nil
        case "relaySettings.v1": fits = decodeFromPlist(merged, as: RelaySettings.self) != nil
        case "smolagents.config.v1": fits = decodeFromPlist(merged, as: SmolAgentsService.Config.self) != nil
        default: fits = true
        }
        guard fits else {
            issues.append(.skipped("“\(key)” doesn't match this version's form: skipped, so yours stays as it is."))
            return nil
        }
        let filled = Set(current.keys).subtracting(imported.keys).sorted()
        if !filled.isEmpty, !current.isEmpty { issues.append(.filled("“\(key)”: \(list(filled)) not in the file, so yours \(filled.count == 1 ? "is" : "are") kept.")) }
        return merged
    }

    /// What a brand-new bot starts with, for filling in fields an older file doesn't have.
    private static func defaultBotConfig(name: String, id: String) -> BotConfig {
        BotConfig(
            id: id, name: name, colorHex: "#5E5CE6", avatarStyle: 0, tagline: "", group: "General", systemPromptText: "",
            selectedSkillIDs: Set(SkillLibrary.loadAll().map(\.id)), selectedModel: "qwen2.5:7b-instruct", modelHasVision: true,
            maxTokensText: UserDefaults.standard.string(forKey: "defaultMaxTokens") ?? "200000",
            maxIterationsText: UserDefaults.standard.string(forKey: "defaultMaxIterations") ?? "40",
            modelProvider: nil, remoteBaseURLText: nil, engine: nil
        )
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
