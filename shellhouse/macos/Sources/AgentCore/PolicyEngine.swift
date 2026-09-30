import Foundation

/// Tool schema as the model sees it.
public struct ToolSchema: Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: Any]

    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Policy engine.
///
/// The enforceable boundary between "the model decided to do X" and "X
/// actually ran." Ported from the Python implementation with the rules table
/// unchanged, deliberately — the reasoning behind each entry is in
/// docs/SECURITY.md, and divergence between the two builds would be a bug.
public enum Policy: Sendable {
    public enum Decision: String, Sendable {
        case allow = "ALLOW"
        case requireApproval = "REQUIRE_APPROVAL"
        case deny = "DENY"
    }

    /// Default rules. Anything absent falls through to `requireApproval` —
    /// an unrecognized tool asks a human rather than assuming it is safe.
    public static let defaults: [String: Decision] = [
        // Read-only / low risk
        "list_files": .allow,
        "read_file": .allow,
        "write_file": .allow,
        "web_search": .allow,
        "fetch_url": .allow,

        // Computer use: observing the desktop is free, and acting on it is
        // allowed because it is confined to the sandbox VM's own GUI. Tighten
        // these to requireApproval if the agent is ever logged into real
        // accounts inside that VM.
        "screenshot": .allow,
        "list_windows": .allow,
        "focus_window": .allow,
        "open_app": .allow,
        "click": .allow,
        "type_text": .allow,
        "press_key": .allow,
        "scroll": .allow,

        // Memory: recording and recalling task findings is routine.
        // `remember` used to require approval (the user decides what's
        // kept about them) — dropped to `.allow` since bots are now
        // instructed to remember proactively (see `BuiltInSystemPrompt`),
        // and a per-call approval prompt for that would defeat the point.
        // Still visible/removable after the fact in the bot's own
        // Settings sheet, so nothing written this way is silently
        // unreviewable.
        "save_evidence": .allow,
        "search_memory": .allow,
        "remember": .allow,
        "recall_memory": .allow,
        // Same tier as remember/recall_memory — self-scoped, no side
        // effects outside this bot's own task list.
        "remember_task": .allow,
        "complete_task": .allow,
        "list_tasks": .allow,
        // The routine itself is inert (just a scheduled message to the
        // bot) — whatever it does once triggered still goes through the
        // normal per-tool approval flow same as any other message.
        "create_routine": .allow,
        "edit_routine": .allow,
        // Destructive, but only ever to this bot's own scheduled
        // routines — low stakes (trivially recreated with create_routine
        // if wrong) and exact-match duplicate detection only (see
        // `Bot.duplicateRoutinesToRemove`), not fuzzy matching that could
        // misfire on something the user actually wanted kept.
        "remove_routine": .allow,
        // Both purely read-only, self-scoped, no side effects.
        "list_routines": .allow,
        "get_profile": .allow,

        // Read-only directory lookup, and a delegation that's inert on its
        // own — whatever the recipient bot actually DOES once delegated to
        // still goes through its own approval flow for that tool, same as
        // if its own user had asked directly.
        "list_bots": .allow,
        "message_bot": .allow,

        // Spins up a brand-new persistent sandbox/container — a real
        // resource-creating action, same bar as `run_shell`.
        "create_bot": .requireApproval,

        // Just edits a group's membership list (capped at 6, reversible) —
        // no sandbox, no side effects outside this app's own state.
        "add_bot_to_group": .allow,

        // Posts text the bot itself wrote into a group it already belongs
        // to — no side effects beyond that group's transcript.
        "post_to_group": .allow,

        // Adds a line to this bot's own 1:1 chat — no effect on anyone else.
        "update_user": .allow,

        // Group goal checklist — state inside this app only.
        "get_goal": .allow,
        "propose_goal": .allow,
        "add_goal_step": .allow,
        "update_goal_step": .allow,
        "propose_goal_complete": .allow,

        // Credential NAMES are safe to reveal; no tool returns a value.
        "list_secrets": .allow,

        // Arbitrary command execution pauses for a human by default; the
        // approval card offers per-binary and blanket ("allow all shell
        // commands") grants — see `RunShellPermissions`.
        "run_shell": .requireApproval,

        // Loads a skill's own text into context — read-only, no side effects.
        "use_skill": .allow,
    ]

    /// Classify a tool call.
    ///
    /// MCP tools are namespaced `mcp__<server>__<tool>` and default to
    /// approval, because a third-party server's tool is remote code execution
    /// with your credentials attached. A server explicitly marked trusted may
    /// run its read-only-looking tools without asking — an operator decision,
    /// not a default.
    public static func evaluate(
        tool: String,
        mcpTrustedServers: Set<String> = [],
        mcpReadOnlyHint: ((String) -> Bool)? = nil
    ) -> Decision {
        if tool.hasPrefix("mcp__") {
            let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return .deny }
            // mcp__<server>__<tool>
            let serverName = tool
                .dropFirst("mcp__".count)
                .components(separatedBy: "__")
                .first ?? ""
            guard !serverName.isEmpty else { return .deny }
            if mcpTrustedServers.contains(serverName),
               mcpReadOnlyHint?(tool) == true {
                return .allow
            }
            return .requireApproval
        }
        return defaults[tool] ?? .requireApproval
    }
}

/// A pending human decision, as durable state.
public struct Approval: Sendable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case pending, approved, denied
    }

    public let id: String
    public let taskID: String
    public let toolName: String
    public let argumentsSummary: String
    public var status: Status
    public let createdAt: Date
    public var decidedAt: Date?
    /// For `run_shell` only: the extracted binary name (see
    /// `RunShellPermissions.extractBinary`), if this approval is eligible
    /// for an "always allow" decision. `nil` for every other tool.
    public let alwaysAllowCandidate: String?
    /// Raised during a turn that included a friend's (untrusted) message:
    /// this call needs an explicit yes every time, and no standing grant
    /// ("always allow", "allow all shell") applies or can be created from it.
    public let untrusted: Bool

    public init(
        id: String = "apr_\(UUID().uuidString.prefix(12))",
        taskID: String,
        toolName: String,
        argumentsSummary: String,
        status: Status = .pending,
        createdAt: Date = Date(),
        decidedAt: Date? = nil,
        alwaysAllowCandidate: String? = nil,
        untrusted: Bool = false
    ) {
        self.id = id
        self.taskID = taskID
        self.toolName = toolName
        self.argumentsSummary = argumentsSummary
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.alwaysAllowCandidate = alwaysAllowCandidate
        self.untrusted = untrusted
    }
}
