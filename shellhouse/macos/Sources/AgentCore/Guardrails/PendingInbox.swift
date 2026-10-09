import Foundation

/// A durable change (a memory, a routine) the agent tried to make during a run
/// that had read untrusted content. It is held here until the user approves,
/// so prompt-injected instructions can't plant persistent memories or
/// scheduled jobs (docs/GUARDRAILS.md, L2).
public struct PendingItem: Codable, Identifiable, Sendable {
    public let id: String
    public let botID: String
    public let tool: String
    public let arguments: [String: AnyCodable]
    /// Human-readable one-liner shown in the review list.
    public let summary: String
    public let sources: [String]
    public let createdAt: Date

    public init(botID: String, tool: String, arguments: [String: AnyCodable], summary: String, sources: [String]) {
        self.id = "pnd_\(UUID().uuidString.prefix(10))"
        self.botID = botID
        self.tool = tool
        self.arguments = arguments
        self.summary = Redactor.redact(summary, limit: 400)
        self.sources = sources
        self.createdAt = Date()
    }
}

public struct PendingInboxStore: Sendable {
    public static let maxItemsPerBot = 50
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: PendingInboxStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICompute/pending-review", isDirectory: true)
        return PendingInboxStore(directory: dir)
    }

    private func fileURL(_ botID: String) -> URL? {
        // Bot ids are generated ("bot-xxxxxxxx" / "spike"); refuse anything path-like.
        guard !botID.isEmpty, botID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return directory.appendingPathComponent("\(botID).json")
    }

    public func load(botID: String) -> [PendingItem] {
        guard let url = fileURL(botID), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingItem].self, from: data)) ?? []
    }

    @discardableResult
    public func append(_ item: PendingItem) -> Bool {
        guard let url = fileURL(item.botID) else { return false }
        var items = load(botID: item.botID)
        guard items.count < Self.maxItemsPerBot else { return false }
        items.append(item)
        return write(items, to: url)
    }

    public func remove(botID: String, id: String) {
        guard let url = fileURL(botID) else { return }
        _ = write(load(botID: botID).filter { $0.id != id }, to: url)
    }

    public func removeAll(botID: String) {
        guard let url = fileURL(botID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ items: [PendingItem], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Builds the best-effort snapshot command run (inside the sandbox) before a
/// deletion / overwrite, so a wrong approval is recoverable.
public enum Checkpoint {
    public static let trashDirectory = "/workspace/.shellhouse/trash"
    static let maxPaths = 20

    /// Single-quote a string for POSIX shells.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `nil` when there is nothing in the workspace worth snapshotting.
    public static func command(for paths: [String], stamp: String, config: GuardrailConfig = GuardrailConfig()) -> String? {
        var seen = Set<String>()
        let usable = paths.compactMap { path -> String? in
            let n = ShellAnalyzer.normalize(path: path, cwd: config.cwd, home: config.home)
            guard n == "/workspace" ? false : n.hasPrefix("/workspace/"),
                  !n.hasPrefix(trashDirectory),
                  !n.contains("\u{0}"),
                  seen.insert(n).inserted else { return nil }
            return n
        }.prefix(maxPaths)
        guard !usable.isEmpty else { return nil }
        let safeStamp = stamp.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "T" }
        let dest = "\(trashDirectory)/\(safeStamp)"
        let copies = usable.map { "[ -e \(shellQuote($0)) ] && cp -a --parents \(shellQuote($0)) \(shellQuote(dest))/ 2>/dev/null" }
        return "mkdir -p \(shellQuote(dest)) && { \(copies.joined(separator: "; ")); true; }"
    }
}
