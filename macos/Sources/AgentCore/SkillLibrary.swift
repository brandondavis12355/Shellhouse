import Foundation

/// One `skills/<name>.md` playbook — bundled from `skills/` at the repo root,
/// or added by the user. Each is a self-contained markdown file with a YAML
/// frontmatter (`name:`/`description:`) followed by the playbook body.
public struct Skill: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    /// Full file content (frontmatter included) — this is what gets appended
    /// to a system prompt when a skill is selected, not just the body, so
    /// the model sees the same `name:`/`description:` framing either way.
    public let content: String

    public init(id: String, name: String, description: String, content: String) {
        self.id = id
        self.name = name
        self.description = description
        self.content = content
    }
}

public enum SkillLibrary {
    /// Where skills added via Settings > Skills ("create and paste in new
    /// skills") actually live. The bundled `skills/` folder is inside the
    /// signed `.app` — writing there at runtime isn't possible (and
    /// wouldn't survive an update anyway) — so anything created in the UI
    /// goes here instead, in Application Support, same root as the rest of
    /// this app's own data (`BotPersistence.swift`'s per-bot files).
    public static var userSkillsDirectory: URL {
        let dir = AppData.url("user-skills")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Loads every `skills/*.md` bundled into the app (see `project.yml`'s
    /// folder-reference resource entry) plus every user-added one, merged
    /// by id — a user skill with the same id as a bundled one deliberately
    /// overrides it, so a built-in playbook can be locally customized just
    /// by adding a skill under its exact name. Never throws: a missing
    /// folder just means no skills from that source, not a hard failure.
    public static func loadAll() -> [Skill] {
        var byID: [String: Skill] = [:]
        for skill in loadDirectory(bundledSkillsDirectory) { byID[skill.id] = skill }
        for skill in loadDirectory(userSkillsDirectory) { byID[skill.id] = skill }
        return byID.values.sorted { $0.name < $1.name }
    }

    /// Whether `id` came from `userSkillsDirectory` (and so can be edited
    /// or deleted) rather than the read-only bundled set.
    public static func isUserSkill(id: String) -> Bool {
        FileManager.default.fileExists(atPath: userSkillsDirectory.appendingPathComponent("\(id).md").path)
    }

    public enum SkillError: LocalizedError {
        case invalidID(String)
        public var errorDescription: String? {
            switch self {
            case .invalidID(let id):
                return "Invalid skill id '\(id)' — this shouldn't happen from the Settings UI; report it."
            }
        }
    }

    /// `id` is derived from the display name via `slugify`, not typed by
    /// hand, so validation here is a safety net (guards the filename),
    /// not a form the user has to satisfy directly.
    public static func saveUserSkill(id: String, content: String) throws {
        guard isValidSkillID(id) else { throw SkillError.invalidID(id) }
        let url = userSkillsDirectory.appendingPathComponent("\(id).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func deleteUserSkill(id: String) throws {
        try FileManager.default.removeItem(at: userSkillsDirectory.appendingPathComponent("\(id).md"))
    }

    /// Display name → filename-and-tool-name-safe id: lowercase,
    /// non-alphanumeric collapsed to single hyphens, guaranteed to start
    /// with a letter (the `use_skill` tool matches on this exact string,
    /// and it doubles as the saved file's name).
    public static func slugify(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var slug = String(mapped)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty || !(slug.first?.isLetter ?? false) {
            slug = "skill-" + slug
        }
        return String(slug.prefix(64))
    }

    private static func isValidSkillID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        guard let first = id.first, first.isLetter else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static var bundledSkillsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("skills")
    }

    private static func loadDirectory(_ dirURL: URL?) -> [Skill] {
        guard let dirURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil
              ) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap(loadOne)
    }

    private static func loadOne(_ url: URL) -> Skill? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fallbackID = url.deletingPathExtension().lastPathComponent
        let (name, description) = parseFrontmatter(text, fallbackID: fallbackID)
        return Skill(id: fallbackID, name: name, description: description, content: text)
    }

    /// Deliberately not a general YAML parser — the frontmatter here is
    /// always just `name:` and `description:`, so a line-based scan is
    /// enough and doesn't pull in a YAML dependency for two strings. Does
    /// handle YAML's folded (`>`/`>-`) and literal (`|`/`|-`) block-scalar
    /// indicators for `description:`, since a skill may use a
    /// multi-line description that way — everything else is a plain
    /// same-line `key: value`.
    private static func parseFrontmatter(_ text: String, fallbackID: String) -> (name: String, description: String) {
        let strip = CharacterSet(charactersIn: "'\" ")
        guard text.hasPrefix("---") else { return (fallbackID, "") }
        let parts = text.components(separatedBy: "---")
        guard parts.count >= 2 else { return (fallbackID, "") }

        var name = fallbackID
        var description = ""
        let lines = Array(parts[1].split(separator: "\n", omittingEmptySubsequences: false))
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":") else { index += 1; continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if key == "name" {
                name = rawValue.trimmingCharacters(in: strip)
            } else if key == "description" {
                if rawValue.hasPrefix(">") || rawValue.hasPrefix("|") {
                    // Block scalar: gather the following indented lines.
                    var blockLines: [String] = []
                    var lookahead = index + 1
                    while lookahead < lines.count, lines[lookahead].hasPrefix(" ") || lines[lookahead].isEmpty {
                        blockLines.append(String(lines[lookahead]).trimmingCharacters(in: .whitespaces))
                        lookahead += 1
                    }
                    let joiner = rawValue.hasPrefix("|") ? "\n" : " "
                    description = blockLines.filter { !$0.isEmpty }.joined(separator: joiner)
                    index = lookahead
                    continue
                } else {
                    description = rawValue.trimmingCharacters(in: strip)
                }
            }
            index += 1
        }
        return (name, description)
    }
}
