import Foundation
import AgentCore

/// The *settings* half of a `Bot` — identity plus what's editable in
/// `BotSettingsTab`. Deliberately NOT the transcript (`TranscriptStore`) or
/// the remembered-instructions list (`BotMemoryStore`, in this same file):
/// both grow continuously during use rather than being edited in the
/// settings sheet, and giving each its own small per-bot file means a
/// message or a `remember` call can persist itself immediately without
/// rewriting (or racing on) this whole settings list. See `Bot.config`'s
/// doc comment. Plain `Codable` rather than routing through GRDB (already a
/// dependency, for `MemoryStore`) — each of these is one small
/// value read/written whole, not something that benefits from a query engine.
/// Where a bot's model calls actually go. `.remote`'s API key never lives
/// here (or anywhere in `BotConfig`/`BotTemplate`) — it's Keychain-only,
/// see `Bot.remoteAPIKeySecretName` — so this struct staying `Codable` and
/// getting written to a plain JSON/XML file on disk never risks leaking one.
enum ModelProvider: String, Codable, CaseIterable {
    case ollama
    case remote
}

struct BotConfig: Codable {
    var id: String
    var name: String
    var colorHex: String
    var avatarStyle: Int
    var tagline: String
    var group: String
    var systemPromptText: String
    var selectedSkillIDs: Set<String>
    var selectedModel: String
    var modelHasVision: Bool
    var maxTokensText: String
    var maxIterationsText: String
    /// `nil` decodes as `.ollama` (see `Bot.init(config:)`) — both fields
    /// were added after this struct started shipping, so an already-saved
    /// `bots.json` with neither key must still load.
    var modelProvider: ModelProvider?
    var remoteBaseURLText: String?
}

/// A bot's settings plus memory and routines, portable across export/
/// import (and reused for "Duplicate…") — everything `BotConfig` has
/// EXCEPT `id`, plus `memories`/`routines`. Deliberately excludes the
/// conversation transcript and anything sandbox/container-identity-related:
/// importing one always creates a brand-new bot with its own fresh
/// sandbox, never something that tries to reattach to the source bot's
/// persistent container. See `Bot.asTemplate` and the matching
/// `Bot.init(id:template:permissions:botDirectory:)`.
struct BotTemplate: Codable {
    var name: String
    var colorHex: String
    var avatarStyle: Int
    var tagline: String
    var group: String
    var systemPromptText: String
    var selectedSkillIDs: Set<String>
    var selectedModel: String
    var modelHasVision: Bool
    var maxTokensText: String
    var maxIterationsText: String
    var memories: [String]
    var routines: [Routine]
    /// Same nil-means-`.ollama` back-compat shape as `BotConfig` — a
    /// template's own remote API key (if any) is never included; whoever
    /// imports it enters their own.
    var modelProvider: ModelProvider?
    var remoteBaseURLText: String?

    /// XML rather than JSON — an XML property list (`PropertyListEncoder`
    /// with `.xml` output), the standard Foundation-native way to get a
    /// real, readable `.xml` file out of a `Codable` type without hand-
    /// rolling an XML schema for this one struct.
    static func load(from url: URL) throws -> BotTemplate {
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(BotTemplate.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

/// Persists the sidebar's bot list (as `[BotConfig]`) to a JSON file in
/// Application Support, so bots added, renamed, recolored, or reconfigured
/// in one launch are still there in the next — previously every `Bot` was
/// re-created from scratch on every launch except the hardcoded "spike"
/// bootstrap bot, silently dropping anything the user had changed.
///
/// A plain file rather than `UserDefaults`: this can grow (one entry per
/// bot, each carrying a whole system prompt) past what `UserDefaults` is
/// meant for, and a file is trivial to delete by hand if it's ever
/// corrupted, which `UserDefaults` isn't.
enum BotStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AICompute", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bots.json")
    }

    static func load() -> [BotConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([BotConfig].self, from: data)) ?? []
    }

    /// Overwrites the whole file — the bot list is small enough (a handful
    /// of entries at most) that a full rewrite on every save is simpler
    /// than tracking a diff, and atomic writes mean a crash mid-save can't
    /// leave a half-written file behind.
    static func save(_ configs: [BotConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else {
            print("[BotStore] failed to encode bot configs")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[BotStore] failed to write bots.json: \(error)")
        }
    }
}

/// One persisted conversation turn — plain `role`/`text`, matching
/// `DisplayMessage`. No `images` or `toolCalls`: see `AgentRuntime.seed`'s
/// doc comment for why those aren't carried across a relaunch.
struct TranscriptEntry: Codable {
    var role: ChatMessage.Role
    var text: String
    /// Optional (not a plain `[]` default) so a transcript file saved
    /// before this field existed still decodes — `decodeIfPresent` on a
    /// missing key gives `nil` either way, but spelling it out here as
    /// `Optional` keeps that compatibility obvious rather than relying on
    /// synthesized-`Codable`'s default-value behavior.
    var attachmentNames: [String]?
    /// Marks a "Messaged <name>…" notice (see `Bot.delegateToBot`) rather
    /// than normal chat text — both `nil` for every ordinary message.
    var interBotPeerID: String?
    var interBotPeerName: String?
    /// Optional for the same reason `attachmentNames` is — a transcript
    /// saved before this field existed still decodes, and `Bot`'s loader
    /// falls back to `Date()` for a `nil` (an approximate "now" beats
    /// crashing or losing the message).
    var timestamp: Date?
    /// Same optional-for-back-compat shape — see `DisplayMessage.toolName`/
    /// `.isTaskSummary`.
    var toolName: String?
    var isTaskSummary: Bool?
}

/// Persists one bot's conversation — read back on launch (`Bot`'s `init`s
/// both call this) so closing the app and reopening it finds the same chat
/// still there, not a blank one. Keyed by bot id in its own file rather than
/// folded into `BotConfig`'s single `bots.json`: a message is written on
/// every turn, and that shouldn't mean rewriting (and risking a torn write
/// across) every other bot's settings each time too.
enum TranscriptStore {
    private static func fileURL(for id: String) -> URL {
        dir("transcripts").appendingPathComponent("\(id).json")
    }

    static func load(id: String) -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return [] }
        return (try? JSONDecoder().decode([TranscriptEntry].self, from: data)) ?? []
    }

    static func save(id: String, _ entries: [TranscriptEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            print("[TranscriptStore] failed to encode transcript for bot \(id)")
            return
        }
        do {
            try data.write(to: fileURL(for: id), options: .atomic)
        } catch {
            print("[TranscriptStore] failed to write transcript for bot \(id): \(error)")
        }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

/// A bot's remembered instructions — the `remember` tool's own writes (see
/// `ToolRegistry`'s `onRemember`) plus anything added by hand in the
/// settings sheet's Memory section. Read back into `Bot.memories` on launch
/// and folded into the system prompt by `Bot.fullSystemPrompt()`, so
/// something learned in one conversation actually carries into the next one
/// rather than being scoped to the session that learned it.
enum BotMemoryStore {
    private static func fileURL(for id: String) -> URL {
        dir("memories").appendingPathComponent("\(id).json")
    }

    static func load(id: String) -> [String] {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Returns whether the write actually landed — same reasoning as
    /// `RoutineStore.save`: the `remember` tool tells the model "saved:
    /// true" the moment this returns, and that's a lie if the write
    /// silently failed (this used to be a bare `try?`), since a fact
    /// the model believes is durable would actually vanish the next
    /// time this bot's memories are loaded from disk.
    @discardableResult
    static func save(id: String, _ memories: [String]) -> Bool {
        guard let data = try? JSONEncoder().encode(memories) else {
            print("[BotMemoryStore] failed to encode memories for bot \(id)")
            return false
        }
        do {
            try data.write(to: fileURL(for: id), options: .atomic)
            return true
        } catch {
            print("[BotMemoryStore] failed to write memories for bot \(id): \(error)")
            return false
        }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

/// One "carry this across contexts" one-shot task — distinct from a
/// `memories` entry (a durable instruction/preference, kept forever)
/// and from a `Routine` (fires on a schedule): this is "I've been asked
/// to do X," meant to survive exactly until X is actually done, then go
/// away. The point is continuity: a group turn or delegation has no
/// access to this bot's own 1:1 conversation history (see
/// `Bot.fullSystemPrompt`), so without this, a task assigned in a
/// private chat would be invisible the moment that same bot is asked
/// about it from a group or a delegation.
struct BotTask: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var createdAt: Date = Date()
}

/// Persists one bot's active one-shot tasks — its own file, same
/// reasoning as `RoutineStore`/`BotMemoryStore`: written by the model
/// itself mid-conversation (`remember_task`/`complete_task`), not only
/// edited by hand, so this shouldn't mean rewriting every other bot's
/// settings too.
enum BotTaskStore {
    private static func fileURL(for id: String) -> URL {
        dir("tasks").appendingPathComponent("\(id).json")
    }

    static func load(id: String) -> [BotTask] {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return [] }
        return (try? JSONDecoder().decode([BotTask].self, from: data)) ?? []
    }

    /// Returns whether the write actually landed — same reasoning as
    /// `RoutineStore.save`/`BotMemoryStore.save`: `remember_task`
    /// reports success only when this is true, not just because the
    /// in-memory `Bot.tasks` array was appended to.
    @discardableResult
    static func save(id: String, _ tasks: [BotTask]) -> Bool {
        guard let data = try? JSONEncoder().encode(tasks) else {
            print("[BotTaskStore] failed to encode tasks for bot \(id)")
            return false
        }
        do {
            try data.write(to: fileURL(for: id), options: .atomic)
            return true
        } catch {
            print("[BotTaskStore] failed to write tasks for bot \(id): \(error)")
            return false
        }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

/// A time-based trigger that queues `instruction` to this bot as if the
/// user had typed it — created either by hand in the settings sheet's
/// Routines section, or by the bot itself via the `create_routine` tool.
/// Only time-based schedules for now (see `Schedule`); event-based triggers
/// (file changes, webhooks, etc.) are a different, larger feature and
/// deliberately not implied by this type.
struct Routine: Codable, Identifiable, Equatable {
    enum Schedule: Codable, Equatable {
        case once(Date)
        case daily(hour: Int, minute: Int)
        case interval(minutes: Int)

        /// The next moment this schedule should fire, computed fresh from
        /// `now` rather than stored — so a routine loaded after the app was
        /// quit for a week still lands on the right time instead of an
        /// instant-fire backlog, and a `.once` whose date has already
        /// passed reports `nil` (spent) instead of firing immediately.
        func nextFireDate(after now: Date = Date()) -> Date? {
            switch self {
            case .once(let when):
                return when > now ? when : nil
            case .daily(let hour, let minute):
                let calendar = Calendar.current
                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.hour = hour
                components.minute = minute
                components.second = 0
                guard let candidate = calendar.date(from: components) else { return nil }
                return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)
            case .interval(let minutes):
                return now.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
            }
        }

        /// Shown next to each routine in the settings sheet.
        var summary: String {
            switch self {
            case .once(let when):
                return "Once, \(when.formatted(date: .abbreviated, time: .shortened))"
            case .daily(let hour, let minute):
                return String(format: "Daily at %02d:%02d", hour, minute)
            case .interval(let minutes):
                return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
            }
        }
    }

    var id: String = UUID().uuidString
    var instruction: String
    var schedule: Schedule
    var isEnabled: Bool = true
    var lastFiredAt: Date?
    /// `nil` (the default) fires into this bot's own 1:1 chat, exactly as
    /// before. Set to an existing group's id to instead post there — see
    /// `Bot.fireRoutine`/`GroupChatSession.fireRoutine(for:instruction:)`.
    /// Optional so an already-saved routine from before this field
    /// existed still decodes.
    var targetGroupID: String?
}

/// Persists one bot's routines — its own file for the same reason
/// `TranscriptStore`/`BotMemoryStore` get their own: routines can be
/// created by the model mid-conversation (`create_routine`), not only
/// edited in the settings sheet, and that shouldn't mean rewriting every
/// other bot's settings too.
enum RoutineStore {
    private static func fileURL(for id: String) -> URL {
        dir("routines").appendingPathComponent("\(id).json")
    }

    static func load(id: String) -> [Routine] {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return [] }
        return (try? JSONDecoder().decode([Routine].self, from: data)) ?? []
    }

    /// Returns whether the write actually landed — `create_routine`'s
    /// tool result should say "created" only when this is true, not
    /// just because the in-memory `Bot.routines` array was appended to.
    /// A silently-swallowed failure here (this used to be a bare `try?`
    /// with the result discarded) is exactly how a bot ends up telling
    /// the user a routine exists when a relaunch — reloading fresh from
    /// disk via `load`, with nothing on it — makes it disappear.
    @discardableResult
    static func save(id: String, _ routines: [Routine]) -> Bool {
        guard let data = try? JSONEncoder().encode(routines) else {
            print("[RoutineStore] failed to encode routines for bot \(id)")
            return false
        }
        do {
            try data.write(to: fileURL(for: id), options: .atomic)
            return true
        } catch {
            print("[RoutineStore] failed to write routines for bot \(id): \(error)")
            return false
        }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

/// The model-facing digest of everything before a certain point in one
/// bot's own chat — written whenever `AgentRuntime.compact` summarizes
/// that bot's context (see `Bot.handleEvent`'s `.contextCompacted`
/// case), read back when a fresh `AgentRuntime` needs seeding (an app
/// relaunch, or whenever `Bot.runtime` is `nil`). Without this, that
/// reseed would resend the bot's ENTIRE persisted transcript — which,
/// for a long-running chat, is exactly the oversized history compaction
/// exists to avoid — only to have it immediately re-summarized back
/// down to roughly this same digest on the very next turn anyway.
struct ContextSummary: Codable {
    var text: String
    /// How many of `Bot.displayMessages`, counting from the start, this
    /// summary already covers. An approximation, not an exact index
    /// into `AgentRuntime`'s own (differently-granular — tool calls,
    /// streamed deltas, etc. don't map 1:1 to `displayMessages` rows)
    /// message array: captured as `displayMessages.count` at the moment
    /// the compaction event arrives, since both arrays grow turn-by-turn
    /// together in practice. Stable across appends — the only mutation
    /// `displayMessages` ever gets — so it stays valid until the next
    /// compaction moves it forward.
    var coveredMessageCount: Int
}

enum ContextSummaryStore {
    private static func fileURL(for id: String) -> URL {
        dir("context-summaries").appendingPathComponent("\(id).json")
    }

    static func load(id: String) -> ContextSummary? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(ContextSummary.self, from: data)
    }

    static func save(id: String, _ summary: ContextSummary) {
        guard let data = try? JSONEncoder().encode(summary) else {
            print("[ContextSummaryStore] failed to encode context summary for bot \(id)")
            return
        }
        do {
            try data.write(to: fileURL(for: id), options: .atomic)
        } catch {
            print("[ContextSummaryStore] failed to write context summary for bot \(id): \(error)")
        }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

/// One turn of a bot-to-bot exchange — see `Bot.delegateToBot`. The user
/// never writes into this; it's read-only from the app's side, viewed by
/// tapping the "Messaged <name>…" notice a delegation leaves in the
/// delegating bot's own transcript.
struct InterBotMessage: Codable, Identifiable {
    var id: String = UUID().uuidString
    var fromBotID: String
    var fromBotName: String
    var toBotID: String
    var toBotName: String
    var text: String
    var timestamp: Date = Date()
}

/// One thread per unordered PAIR of bots — a delegation and its reply both
/// land in the same file regardless of which side is asking, keyed by
/// their ids sorted so either direction resolves to the same path.
enum InterBotStore {
    private static func fileURL(for botA: String, _ botB: String) -> URL {
        let key = [botA, botB].sorted().joined(separator: "__")
        return dir("bot-conversations").appendingPathComponent("\(key).json")
    }

    static func load(_ botA: String, _ botB: String) -> [InterBotMessage] {
        guard let data = try? Data(contentsOf: fileURL(for: botA, botB)) else { return [] }
        return (try? JSONDecoder().decode([InterBotMessage].self, from: data)) ?? []
    }

    static func append(_ message: InterBotMessage) {
        var messages = load(message.fromBotID, message.toBotID)
        messages.append(message)
        guard let data = try? JSONEncoder().encode(messages) else {
            print("[InterBotStore] failed to encode thread \(message.fromBotID)/\(message.toBotID)")
            return
        }
        do {
            try data.write(to: fileURL(for: message.fromBotID, message.toBotID), options: .atomic)
        } catch {
            print("[InterBotStore] failed to write thread \(message.fromBotID)/\(message.toBotID): \(error)")
        }
    }
}

private func dir(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AICompute/\(name)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
