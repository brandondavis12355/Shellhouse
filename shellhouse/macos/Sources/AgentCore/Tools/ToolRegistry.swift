import Foundation
import ImageIO

/// Swift port of the sandbox-facing subset of `api/agent/tools.py`'s 17
/// tools — the ones that let the model act inside the VM: files, shell,
/// screenshots, windows, and input. `web_search`/`fetch_url` (external web)
/// and the embedding-backed memory tools (`save_evidence`, `search_memory`,
/// `list_secrets`) are deliberately out of scope. `run_shell`'s `use_secrets` is
/// kept, since `SecretStore` already exists and wiring it is cheap. `remember`
/// IS wired (see `init`'s `onRemember`) — it's a plain per-bot text list, not
/// the embedding-search memory those other tools would need.
public struct ToolRegistry: Sendable {
    public typealias Executor = @Sendable (
        _ sandboxID: String,
        _ sandbox: any SandboxProvider,
        _ arguments: [String: AnyCodable],
        _ secretStore: SecretStore
    ) async -> [String: Any]

    public private(set) var schemas: [ToolSchema]
    private var executors: [String: Executor]

    /// The same registry minus the named tools — neither offered to the model
    /// nor executable if it asks for one anyway.
    public func removing(_ names: Set<String>) -> ToolRegistry {
        var copy = self
        copy.schemas = schemas.filter { !names.contains($0.name) }
        copy.executors = executors.filter { !names.contains($0.key) }
        return copy
    }

    /// `skills` are NOT injected into the system prompt in full — `ContentView`
    /// only puts a name+description index there. Passing them here is what
    /// adds the `use_skill` tool, so a skill's full content only enters the
    /// conversation (as that tool's result) the moment the model actually
    /// decides it needs one, the same lazy-load shape as Claude's own Skill
    /// tool. Without this, every selected skill's full text would resend on
    /// every loop iteration regardless of whether it was ever used.
    ///
    /// `onRemember`, if provided, adds the `remember` tool (`.allow` in
    /// the default `Policy` — bots are instructed to remember
    /// proactively, so a per-call approval prompt would defeat the
    /// point; still visible/removable after the fact in the bot's own
    /// Settings sheet) — the model's own way to add to this bot's
    /// persisted memory list (see `Bot.memories`) instead of that list
    /// being purely user-maintained.
    ///
    /// `onRecallMemory`, if provided, adds `recall_memory` — the read-side
    /// counterpart. Every memory is already resent in full in the system
    /// prompt (see `Bot.fullSystemPrompt`), so this isn't the only way the
    /// model sees them; it exists for the moment the model suspects
    /// something it was told before is relevant *right now* but isn't
    /// obviously front-of-mind in a prompt it only saw once at the start of
    /// the conversation — an explicit "check my notes" action, the same
    /// reason `search_memory` exists in the Python build's tool set.
    /// `onCreateRoutine`, if provided, adds `create_routine` — the model's
    /// own way to schedule a future message to itself (see `Bot.Routine`).
    /// Takes the raw tool arguments rather than a typed schedule: `Routine`
    /// and its `Schedule` enum are defined in the app target
    /// (`BotStore.swift`), not this package, so — the same shape as
    /// `onRemember`/`onRecallMemory` — this stays agnostic of that type and
    /// lets `Bot` parse and validate the arguments itself.
    /// `onListBots`/`onMessageBot`, if provided, add `list_bots` and
    /// `message_bot` — how one bot discovers and talks to another. Same
    /// agnostic-of-the-app-target shape as `onCreateRoutine`: `Bot`/
    /// `BotDirectory` live in the app target, not this package.
    /// `onListRoutines`/`onGetProfile`, if provided, add `list_routines`
    /// and `get_profile` — read-only, live counterparts to the routines/
    /// name/tagline/model/etc. a bot only otherwise sees baked as prose
    /// into its own system prompt at the start of a run (see
    /// `onCreateRoutine`'s doc comment on why that snapshot goes stale).
    public init(
        skills: [Skill] = [],
        onRemember: (@Sendable (String) async -> Bool)? = nil,
        onRecallMemory: (@Sendable (String) async -> [String])? = nil,
        onRememberTask: (@Sendable ([String: AnyCodable]) async -> [String: Any])? = nil,
        onCompleteTask: (@Sendable ([String: AnyCodable]) async -> [String: Any])? = nil,
        onListTasks: (@Sendable () async -> [[String: Any]])? = nil,
        onCreateRoutine: (@Sendable ([String: AnyCodable]) async -> [String: Any])? = nil,
        onEditRoutine: (@Sendable ([String: AnyCodable]) async -> [String: Any])? = nil,
        onRemoveRoutine: (@Sendable ([String: AnyCodable]) async -> [String: Any])? = nil,
        onListRoutines: (@Sendable () async -> [[String: Any]])? = nil,
        onGetProfile: (@Sendable () async -> [String: Any])? = nil,
        onListBots: (@Sendable () async -> [[String: Any]])? = nil,
        onMessageBot: (@Sendable (String, String) async -> [String: Any])? = nil,
        onCreateBot: (@Sendable (String, String, String?) async -> [String: Any])? = nil,
        onAddBotToGroup: (@Sendable (String, String) async -> [String: Any])? = nil,
        onPostToGroup: (@Sendable (String, String) async -> [String: Any])? = nil,
        onUpdateUser: (@Sendable (String) async -> [String: Any])? = nil,
        onAskHelpers: (@Sendable ([String]) async -> [String: Any])? = nil,
        onGoalTool: (@Sendable (String, [String: AnyCodable]) async -> [String: Any])? = nil
    ) {
        var schemas = Self.buildSchemas()
        var executors = Self.buildExecutors()
        if !skills.isEmpty {
            schemas.append(Self.useSkillSchema)
            let byID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
            executors["use_skill"] = { _, _, arguments, _ in
                guard let name = arguments["name"]?.asString else {
                    return ["error": "use_skill requires 'name'"]
                }
                guard let skill = byID[name] else {
                    return ["error": "unknown skill '\(name)' — use one of the exact names given in the skills index"]
                }
                return ["name": skill.id, "content": skill.content]
            }
        }
        if let onRemember {
            schemas.append(Self.rememberSchema)
            executors["remember"] = { _, _, arguments, _ in
                guard let text = arguments["text"]?.asString, !text.isEmpty else {
                    return ["error": "remember requires non-empty 'text'"]
                }
                // Awaited, not fire-and-forget — this used to kick off the
                // actual save as an un-awaited `Task` and report "saved"
                // immediately regardless of whether it landed, the same
                // structural gap `create_routine` had (see its own doc
                // comments) before this was noticed too.
                guard await onRemember(text) else {
                    return ["error": "failed to save to disk — this wasn't actually remembered"]
                }
                return ["saved": true]
            }
        }
        if let onRecallMemory {
            schemas.append(Self.recallMemorySchema)
            executors["recall_memory"] = { _, _, arguments, _ in
                let query = arguments["query"]?.asString ?? ""
                let matches = await onRecallMemory(query)
                return ["matches": matches]
            }
        }
        if let onRememberTask {
            schemas.append(Self.rememberTaskSchema)
            executors["remember_task"] = { _, _, arguments, _ in
                await onRememberTask(arguments)
            }
        }
        if let onCompleteTask {
            schemas.append(Self.completeTaskSchema)
            executors["complete_task"] = { _, _, arguments, _ in
                await onCompleteTask(arguments)
            }
        }
        if let onListTasks {
            schemas.append(Self.listTasksSchema)
            executors["list_tasks"] = { _, _, _, _ in ["tasks": await onListTasks()] }
        }
        if let onCreateRoutine {
            schemas.append(Self.createRoutineSchema)
            executors["create_routine"] = { _, _, arguments, _ in
                await onCreateRoutine(arguments)
            }
        }
        if let onEditRoutine {
            schemas.append(Self.editRoutineSchema)
            executors["edit_routine"] = { _, _, arguments, _ in
                await onEditRoutine(arguments)
            }
        }
        if let onRemoveRoutine {
            schemas.append(Self.removeRoutineSchema)
            executors["remove_routine"] = { _, _, arguments, _ in
                await onRemoveRoutine(arguments)
            }
        }
        if let onListRoutines {
            schemas.append(Self.listRoutinesSchema)
            executors["list_routines"] = { _, _, _, _ in ["routines": await onListRoutines()] }
        }
        if let onGetProfile {
            schemas.append(Self.getProfileSchema)
            executors["get_profile"] = { _, _, _, _ in await onGetProfile() }
        }
        if let onListBots {
            schemas.append(Self.listBotsSchema)
            executors["list_bots"] = { _, _, _, _ in ["bots": await onListBots()] }
        }
        if let onMessageBot {
            schemas.append(Self.messageBotSchema)
            executors["message_bot"] = { _, _, arguments, _ in
                guard let to = arguments["to"]?.asString, !to.isEmpty,
                      let message = arguments["message"]?.asString, !message.isEmpty else {
                    return ["error": "message_bot requires 'to' and 'message'"]
                }
                return await onMessageBot(to, message)
            }
        }
        if let onCreateBot {
            schemas.append(Self.createBotSchema)
            executors["create_bot"] = { _, _, arguments, _ in
                guard let name = arguments["name"]?.asString, !name.isEmpty,
                      let tagline = arguments["tagline"]?.asString, !tagline.isEmpty else {
                    return ["error": "create_bot requires 'name' and 'tagline'"]
                }
                return await onCreateBot(name, tagline, arguments["system_prompt"]?.asString)
            }
        }
        if let onAddBotToGroup {
            schemas.append(Self.addBotToGroupSchema)
            executors["add_bot_to_group"] = { _, _, arguments, _ in
                guard let botName = arguments["bot_name"]?.asString, !botName.isEmpty,
                      let groupName = arguments["group_name"]?.asString, !groupName.isEmpty else {
                    return ["error": "add_bot_to_group requires 'bot_name' and 'group_name'"]
                }
                return await onAddBotToGroup(botName, groupName)
            }
        }
        if let onGoalTool {
            for schema in Self.goalSchemas {
                schemas.append(schema)
                let toolName = schema.name
                executors[toolName] = { _, _, arguments, _ in await onGoalTool(toolName, arguments) }
            }
        }
        if let onUpdateUser {
            schemas.append(Self.updateUserSchema)
            executors["update_user"] = { _, _, arguments, _ in
                guard let message = arguments["message"]?.asString, !message.isEmpty else {
                    return ["error": "update_user requires a non-empty 'message'"]
                }
                return await onUpdateUser(message)
            }
        }
        if let onAskHelpers {
            schemas.append(Self.askHelpersSchema)
            executors["ask_helpers"] = { _, _, arguments, _ in
                guard let raw = arguments["tasks"]?.value as? [Any] else {
                    return ["error": "ask_helpers requires 'tasks': a list of 1-\(ModelTiers.helperLimit) self-contained prompts"]
                }
                let tasks = raw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !tasks.isEmpty else { return ["error": "ask_helpers got no usable tasks"] }
                return await onAskHelpers(Array(tasks.prefix(ModelTiers.helperLimit)))
            }
        }
        if let onPostToGroup {
            schemas.append(Self.postToGroupSchema)
            executors["post_to_group"] = { _, _, arguments, _ in
                guard let groupName = arguments["group_name"]?.asString, !groupName.isEmpty,
                      let message = arguments["message"]?.asString, !message.isEmpty else {
                    return ["error": "post_to_group requires 'group_name' and 'message'"]
                }
                return await onPostToGroup(groupName, message)
            }
        }
        self.schemas = schemas
        self.executors = executors
    }

    private static var useSkillSchema: ToolSchema {
        ToolSchema(
            name: "use_skill",
            description: "Load the full playbook for one of the skills listed in the system prompt's skill "
                + "index. Only call this for a skill whose one-line description actually matches what you're "
                + "about to do — don't load one you don't need.",
            parameters: [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "Exact skill name from the index."]],
                "required": ["name"],
            ]
        )
    }

    private static var rememberSchema: ToolSchema {
        ToolSchema(
            name: "remember",
            description: "Save one short, durable instruction or preference about how to work with this bot — "
                + "a correction the user gave, a standing preference, a fact worth not re-learning. It's shown "
                + "to the user in this bot's settings and resent at the start of every future conversation "
                + "with it. Don't use this for task-specific facts that only matter to what you're doing right "
                + "now — those belong in your own reasoning, not here. Capped at the 60 most recent — check "
                + "recall_memory first so you don't save a near-duplicate of something you already have.",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "One instruction or preference, in plain language."]],
                "required": ["text"],
            ]
        )
    }

    private static var recallMemorySchema: ToolSchema {
        ToolSchema(
            name: "recall_memory",
            description: "Search this bot's remembered instructions/preferences — the ones saved via "
                + "`remember`, plus anything the user added by hand in settings — for ones relevant to a "
                + "query. Everything remembered is already in your system prompt, so this is for double-"
                + "checking whether something you were told before applies to what you're doing right now, "
                + "not the only way you'd ever see it.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "What to look for, e.g. a name, topic, or situation."]],
                "required": ["query"],
            ]
        )
    }

    private static var rememberTaskSchema: ToolSchema {
        ToolSchema(
            name: "remember_task",
            description: "Save a one-shot task you've been assigned — proactively, the moment you're given "
                + "one, the same way you'd use `remember` for a durable preference. Unlike `remember`, this "
                + "is for something with an end: \"finish X,\" not \"always do Y.\" The point is continuity — "
                + "a group turn or a delegation has no access to this conversation's history, so if a task "
                + "assigned here matters there too, this is the only way it carries over. Call `complete_task` "
                + "the moment it's actually done; don't let finished tasks pile up.",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "The task, in plain language, e.g. \"Draft the Q3 budget summary for the user.\""]],
                "required": ["text"],
            ]
        )
    }

    private static var completeTaskSchema: ToolSchema {
        ToolSchema(
            name: "complete_task",
            description: "Mark one of your own one-shot tasks (see list_tasks for exact ids) as done — "
                + "removes it outright, since a finished task has nothing left to track.",
            parameters: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Exact task id from list_tasks."]],
                "required": ["id"],
            ]
        )
    }

    private static var listTasksSchema: ToolSchema {
        ToolSchema(
            name: "list_tasks",
            description: "See your own current one-shot tasks, live — the system prompt already lists these "
                + "as of when this run started, but that goes stale the moment `remember_task`/`complete_task` "
                + "runs mid-run.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        )
    }

    private static var createRoutineSchema: ToolSchema {
        ToolSchema(
            name: "create_routine",
            description: "Schedule a future action — time-based only for now (a specific moment, a daily "
                + "time, or a repeating interval). By default it fires as a message to yourself, queued "
                + "exactly as if the user had just typed it — write `instruction` the way you'd want a user "
                + "message to read (e.g. \"Check the deploy status and report back\"), not as a note to "
                + "yourself. Set `target_group` to instead have it fire as a directed action inside a group "
                + "chat you're already a member of (see list_bots/add_bot_to_group) — you'll be told to act "
                + "on `instruction` and post the result there, not asked to just chat about it. Shown to the "
                + "user in this bot's settings, where they can also remove it. Idempotent: calling this "
                + "again with the exact same instruction/schedule/target as one you already have returns "
                + "`{\"created\": false, \"already_existed\": true, ...}` with that existing routine's id "
                + "instead of making a duplicate — that's a normal, successful outcome, not a failure, so "
                + "don't retry or report it as an error.",
            parameters: [
                "type": "object",
                "properties": [
                    "instruction": [
                        "type": "string",
                        "description": "What to do when this fires — sent to you as the message, or (with target_group set) as a directed action to complete and post there.",
                    ],
                    "schedule_type": [
                        "type": "string",
                        "enum": ["once", "daily", "interval_minutes"],
                    ],
                    "at": [
                        "type": "string",
                        "description": "Required for schedule_type 'once': an ISO 8601 date-time in the future.",
                    ],
                    "hour": ["type": "integer", "description": "Required for schedule_type 'daily': 0-23."],
                    "minute": ["type": "integer", "description": "Required for schedule_type 'daily': 0-59."],
                    "minutes": [
                        "type": "integer",
                        "description": "Required for schedule_type 'interval_minutes': how often, in minutes.",
                    ],
                    "target_group": [
                        "type": "string",
                        "description": "Optional. Exact name of an existing group chat you're already a member of — fires this routine there instead of your own 1:1 chat.",
                    ],
                ],
                "required": ["instruction", "schedule_type"],
            ]
        )
    }

    private static var editRoutineSchema: ToolSchema {
        ToolSchema(
            name: "edit_routine",
            description: "Change one or more fields of a routine you already have (see list_routines for "
                + "the exact id) — a wrong time, a typo in the instruction, moving it to a different group, "
                + "or disabling it without deleting it. Only the fields you actually pass get changed; "
                + "everything else stays as it was. Prefer this over remove_routine + create_routine for a "
                + "small correction — that loses the routine's history and gives it a new id for no reason.",
            parameters: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Exact routine id from list_routines."],
                    "instruction": ["type": "string", "description": "New instruction text, if changing it."],
                    "schedule_type": [
                        "type": "string",
                        "enum": ["once", "daily", "interval_minutes"],
                        "description": "New schedule shape, if changing it — pass the matching 'at'/'hour'+'minute'/'minutes' field alongside it, same as create_routine.",
                    ],
                    "at": ["type": "string", "description": "New value for schedule_type 'once' — an ISO 8601 date-time in the future."],
                    "hour": ["type": "integer", "description": "New value for schedule_type 'daily': 0-23."],
                    "minute": ["type": "integer", "description": "New value for schedule_type 'daily': 0-59."],
                    "minutes": ["type": "integer", "description": "New value for schedule_type 'interval_minutes'."],
                    "target_group": [
                        "type": "string",
                        "description": "New target group name, if changing it. Pass an empty string to clear it back to your own 1:1 chat.",
                    ],
                    "enabled": ["type": "boolean", "description": "Pass false to pause it without deleting it, or true to re-enable it."],
                ],
                "required": ["id"],
            ]
        )
    }

    private static var removeRoutineSchema: ToolSchema {
        ToolSchema(
            name: "remove_routine",
            description: "Remove one of your own scheduled routines. Pass 'id' (from list_routines) to "
                + "remove that specific one. Omit 'id' to instead auto-detect and remove DUPLICATE "
                + "routines — ones with the exact same instruction, schedule, and target as another "
                + "routine you already have — keeping one of each duplicate set. Use the no-id form "
                + "whenever list_routines shows more than one routine doing the same thing, instead of "
                + "leaving the extras scheduled.",
            parameters: [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Exact routine id from list_routines. Omit to auto-remove duplicates instead.",
                    ],
                ],
            ]
        )
    }

    private static var listRoutinesSchema: ToolSchema {
        ToolSchema(
            name: "list_routines",
            description: "See this bot's own currently scheduled routines — id, schedule, instruction, "
                + "whether it's enabled, and when it'll next fire. The system prompt already lists these as "
                + "of when this run started, but that's stale the moment you call create_routine yourself in "
                + "this same run — call this for a live check, e.g. right after creating one to confirm it "
                + "actually took, or before creating one to check you're not duplicating an existing "
                + "routine. Call it ONCE and act on the result: an empty list, or one without the routine "
                + "you're looking for, means it doesn't exist — that's your answer, so call create_routine "
                + "right then. Calling this again to double-check the same thing won't change the answer.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        )
    }

    private static var getProfileSchema: ToolSchema {
        ToolSchema(
            name: "get_profile",
            description: "See your own current name, tagline/role, model, color, selected skills, memory/"
                + "routine counts, and which group chats you're a member of — read live, not from the "
                + "possibly-stale prose in your own system prompt. Useful when you need to confirm one of "
                + "these facts rather than assume it, especially in a group turn or delegated task where "
                + "this is the only way to check.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        )
    }

    private static var listBotsSchema: ToolSchema {
        ToolSchema(
            name: "list_bots",
            description: "See what other bots exist on this Mac and what each one handles (its role), so you "
                + "know who to delegate to when something is outside your own scope. The system prompt already "
                + "lists them as of when this conversation started; call this for a live check if you suspect "
                + "that's stale (a bot added, removed, or renamed since).",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        )
    }

    private static var messageBotSchema: ToolSchema {
        ToolSchema(
            name: "message_bot",
            description: "Delegate something to another bot by name (see list_bots) and wait for its answer — "
                + "for when the user @mentions one asking you to coordinate with them, or when something is "
                + "outside your own scope and one of them specializes in it. This happens in the background: "
                + "the user sees only a \"Messaged <name>…\" notice in this chat, not the exchange itself, "
                + "unless they tap it. YOU relay the answer back once you have it — don't just report that "
                + "you messaged them and stop. Once you learn which bot handles something, use the remember "
                + "tool so you don't have to re-check next time.",
            parameters: [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Exact name of the bot to delegate to."],
                    "message": ["type": "string", "description": "What you need from them."],
                ],
                "required": ["to", "message"],
            ]
        )
    }

    private static var createBotSchema: ToolSchema {
        ToolSchema(
            name: "create_bot",
            description: "Create a brand-new bot with its own sandbox — for when something is outside your "
                + "own scope AND no existing bot (see list_bots) specializes in it either, so you're "
                + "recruiting a specialist rather than handling it yourself. The new bot boots its own "
                + "sandbox in the background and starts with no conversation and no memory, so give it a "
                + "clear tagline — its role, shown in every bot's \"other bots\" index — and, if its role "
                + "needs instructions beyond the standard default, a system_prompt (prepended to that "
                + "default, not a replacement for it). This is a real, persistent bot the "
                + "user will see in their sidebar, not a throwaway — don't create one speculatively, and "
                + "check list_bots first in case a suitable one already exists.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The new bot's display name."],
                    "tagline": [
                        "type": "string",
                        "description": "Short role description, e.g. \"Handles travel bookings\" — shown to every other bot.",
                    ],
                    "system_prompt": [
                        "type": "string",
                        "description": "Optional. Role-specific instructions for this bot — prepended to the standard default system prompt (tool inventory, finish_task rule, etc.), not a replacement for it. Only what THIS role needs beyond the default; don't restate the default's own mechanics.",
                    ],
                ],
                "required": ["name", "tagline"],
            ]
        )
    }

    private static var goalSchemas: [ToolSchema] {
        func schema(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> ToolSchema {
            ToolSchema(name: name, description: description, parameters: ["type": "object", "properties": properties, "required": required])
        }
        let str: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        return [
            schema("get_goal", "Read the group's current goal, its checklist (with step ids), and progress. Read-only.", [:], required: []),
            schema("propose_goal",
                   "Group goal owner only, and only when there is no live goal: turn the user's actionable request into a goal with a short checklist of concrete, verifiable steps. Do not use for questions or small talk.",
                   ["title": str("One-line goal."),
                    "steps": ["type": "array", "items": ["type": "string"], "description": "2-8 concrete steps, in order."]],
                   required: ["title", "steps"]),
            schema("add_goal_step", "Goal owner only: append a step to the checklist.", ["text": str("The new step.")], required: ["text"]),
            schema("update_goal_step",
                   "Update a checklist step. Set 'inProgress' when you take it on, 'blocked' (with the reason as evidence) if you can't proceed, or 'done' — done REQUIRES evidence: what you ran or checked in THIS turn and what it showed. If you are NOT the goal owner, 'done' only SUBMITS the step for validation (shown as [?]); the goal owner re-checks it with their own tools and is the only one who can mark it truly done. Only the owner's validated completions count as progress.",
                   ["step_id": str("Step id from get_goal / the goal block."),
                    "status": ["type": "string", "enum": ["inProgress", "done", "blocked"]],
                    "evidence": str("Required for done: what you did/checked and the result."),
                    "assignee": str("Optional: who is on it (usually you).")],
                   required: ["step_id", "status"]),
            schema("propose_goal_complete",
                   "Goal owner only: when every step is done (or blocked with a reason), propose the goal as complete. The user must confirm. Give a short summary of the outcome.",
                   ["summary": str("What was accomplished, and any blocked items.")], required: ["summary"]),
        ]
    }

    private static var askHelpersSchema: ToolSchema {
        ToolSchema(
            name: "ask_helpers",
            description: "Run up to \(ModelTiers.helperLimit) small, independent sub-tasks IN PARALLEL on a fast helper model and get "
                + "all the answers back at once. Good for: summarizing or extracting from text you already have, drafting "
                + "variants, classifying, quick lookups from your own knowledge. Helpers have NO tools, no files and no memory "
                + "of this conversation, so each task must contain everything needed (paste the text in). Don't use it for "
                + "work that needs the sandbox, or for anything you can answer in one step yourself.",
            parameters: [
                "type": "object",
                "properties": [
                    "tasks": ["type": "array", "items": ["type": "string"],
                              "description": "Self-contained prompts, one per sub-task."],
                ],
                "required": ["tasks"],
            ]
        )
    }

    private static var updateUserSchema: ToolSchema {
        ToolSchema(
            name: "update_user",
            description: "Post a short status message into your own private 1:1 chat with your user, so they "
                + "see what's happening even though you're working somewhere else (a group chat, a delegated "
                + "request, a routine). Use it for meaningful news — something finished, a result, a blocker, "
                + "a decision that needs them, or a heads-up about what you just did in a group. Not for "
                + "play-by-play. Write it as you'd tell the user directly. Does not notify anyone else.",
            parameters: [
                "type": "object",
                "properties": [
                    "message": ["type": "string", "description": "What to tell the user, in plain language."],
                ],
                "required": ["message"],
            ]
        )
    }

    private static var postToGroupSchema: ToolSchema {
        ToolSchema(
            name: "post_to_group",
            description: "Post a message into a group chat you're already a member of, right now, exactly as "
                + "written — it appears under your name. Use it when asked to tell, announce, or ask something "
                + "in a group. @mention a member by name (or @everyone) to call on them; they'll be prompted "
                + "to respond. Write the actual message text, not a description of it.",
            parameters: [
                "type": "object",
                "properties": [
                    "group_name": ["type": "string", "description": "Exact name of the group chat (you must be a member)."],
                    "message": ["type": "string", "description": "The full message to post, verbatim."],
                ],
                "required": ["group_name", "message"],
            ]
        )
    }

    private static var addBotToGroupSchema: ToolSchema {
        ToolSchema(
            name: "add_bot_to_group",
            description: "Add a bot — yourself or another, by exact name (see list_bots) — to an existing "
                + "named group chat. Groups are capped at 6 members; this fails if the group is already full "
                + "or no group with that name exists. Useful right after create_bot, if the new specialist "
                + "should join a group the user is already coordinating in.",
            parameters: [
                "type": "object",
                "properties": [
                    "bot_name": ["type": "string", "description": "Exact name of the bot to add — can be your own name."],
                    "group_name": ["type": "string", "description": "Exact name of the existing group chat."],
                ],
                "required": ["bot_name", "group_name"],
            ]
        )
    }

    public func names() -> Set<String> { Set(executors.keys) }

    public func execute(
        name: String,
        arguments: [String: AnyCodable],
        sandboxID: String,
        sandbox: any SandboxProvider,
        secretStore: SecretStore
    ) async -> [String: Any] {
        guard let executor = executors[name] else {
            return ["error": "unknown tool '\(name)'"]
        }
        return await executor(sandboxID, sandbox, arguments, secretStore)
    }

    // MARK: - Shell helpers

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func sanitizeFilename(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let base = (name as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }

    /// Shared by `screenshot` and — critically — by `click`/`type_text`
    /// themselves. Verification screenshots kept getting skipped when they
    /// depended on the model remembering to call `screenshot` as a separate
    /// step (see the system prompt's now-defunct "take a screenshot
    /// afterward to confirm" instruction, which this model repeatedly
    /// ignored in practice): attaching one directly to the acting tool's own
    /// result makes verification unconditional instead of advisory.
    private static func captureScreenshot(
        sandboxID: String,
        sandbox: any SandboxProvider,
        filenameHint: String? = nil
    ) async -> (filename: String, bytes: Int, base64: String)? {
        let filename = sanitizeFilename(filenameHint) ?? "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        let absolutePath = "/workspace/\(filename)"
        guard let captured = try? await sandbox.exec(sandboxID, command: "scrot \(quote(absolutePath))", timeout: 20, env: nil),
              captured.exitCode == 0,
              let data = try? await sandbox.readFile(sandboxID, path: filename, maxBytes: 10_000_000) else {
            return nil
        }
        return (filename, data.count, compressedForModel(data).base64EncodedString())
    }

    /// PNG -> JPEG (q≈0.7) at the SAME pixel dimensions, for what's sent
    /// to the model only (the file in the sandbox stays PNG). Same size
    /// matters: click coordinates the model reads off the image must stay
    /// valid, so this deliberately does not downscale. Screenshots are
    /// typically 5-10x smaller as JPEG, which cuts request size and base64
    /// cost every iteration. Falls back to the original bytes on any failure.
    private static func compressedForModel(_ png: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return png }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length < png.count else { return png }
        return output as Data
    }

    // MARK: - Schemas

    private static func buildSchemas() -> [ToolSchema] {
        [
            ToolSchema(
                name: "list_files",
                description: "List files and directories under a path in the sandbox's /workspace.",
                parameters: [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Relative to /workspace. Defaults to /workspace itself."]],
                ]
            ),
            ToolSchema(
                name: "read_file",
                description: "Returns the text of one file in the sandbox (up to 200,000 bytes). Use it to read a file you know the path of; to find files, use list_files or run_shell with find/grep. Paths are relative to /workspace unless absolute. An error means the path is wrong or unreadable: list the parent directory before retrying.",
                parameters: [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                ]
            ),
            ToolSchema(
                name: "write_file",
                description: "Replaces the ENTIRE contents of one file in /workspace with `content` (creates it if missing). Read the file first if you only mean to change part of it, and write the full corrected text. Returns ok or an error naming the problem.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"],
                    ],
                    "required": ["path", "content"],
                ]
            ),
            ToolSchema(
                name: "run_shell",
                description: "Runs one bash command in YOUR OWN Linux VM (user `box`, passwordless sudo, Debian) and returns {exit_code, stdout, stderr}. Check the OUTPUT, not just exit_code: a chained command (`a; echo exit=$?`) can exit 0 around a failure. Prefer one simple command per call, `command -v <tool>` to test for a program, absolute paths, and `| head`/`| tail` for big output (long output is cut in the middle). Do not repeat a command whose result you already have; if it printed nothing or failed, change the approach. Package installs: `sudo apt-get update` first if lookups come back empty.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string"],
                        "timeout": ["type": "integer", "description": "Seconds, default 120."],
                        "use_secrets": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Names of stored secrets to inject as environment variables for this command only.",
                        ],
                    ],
                    "required": ["command"],
                ]
            ),
            ToolSchema(
                name: "screenshot",
                description: "Capture the sandbox desktop and return it as an image the model can see.",
                parameters: [
                    "type": "object",
                    "properties": ["filename": ["type": "string", "description": "Optional; defaults to a timestamped name."]],
                ]
            ),
            ToolSchema(
                name: "list_windows",
                description: "List the sandbox desktop's open windows with their positions and titles.",
                parameters: ["type": "object", "properties": [:]]
            ),
            ToolSchema(
                name: "focus_window",
                description: "Raise and focus a window by (partial) title match.",
                parameters: [
                    "type": "object",
                    "properties": ["title": ["type": "string"]],
                    "required": ["title"],
                ]
            ),
            ToolSchema(
                name: "open_app",
                description: "Launch an application on the sandbox desktop.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "enum": ["browser", "terminal", "files"]],
                        "url": ["type": "string", "description": "Only used when app is 'browser'."],
                    ],
                    "required": ["app"],
                ]
            ),
            ToolSchema(
                name: "click",
                description: "Move the mouse to absolute screen coordinates and click.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "x": ["type": "integer"],
                        "y": ["type": "integer"],
                        "button": ["type": "integer", "description": "1=left, 2=middle, 3=right. Default 1."],
                    ],
                    "required": ["x", "y"],
                ]
            ),
            ToolSchema(
                name: "type_text",
                description: "Type text into whichever window currently has focus.",
                parameters: [
                    "type": "object",
                    "properties": ["text": ["type": "string"]],
                    "required": ["text"],
                ]
            ),
            ToolSchema(
                name: "press_key",
                description: "Press a key or key combo (xdotool syntax, e.g. 'Return', 'ctrl+l').",
                parameters: [
                    "type": "object",
                    "properties": ["key": ["type": "string"]],
                    "required": ["key"],
                ]
            ),
            ToolSchema(
                name: "scroll",
                description: "Scroll a page or window up or down, at the current mouse position or at "
                    + "given coordinates. Each unit is roughly one mouse-wheel click.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "direction": ["type": "string", "enum": ["up", "down"]],
                        "amount": ["type": "integer", "description": "Wheel clicks, default 5."],
                        "x": ["type": "integer", "description": "Optional; moves the mouse here first."],
                        "y": ["type": "integer", "description": "Optional; moves the mouse here first."],
                    ],
                    "required": ["direction"],
                ]
            ),
        ]
    }

    // MARK: - Executors

    private static func buildExecutors() -> [String: Executor] {
        [
            "list_files": { sandboxID, sandbox, args, _ in
                let path = args["path"]?.asString ?? ""
                let target = (path.isEmpty || path == ".") ? "/workspace" : "/workspace/\(path)"
                do {
                    let result = try await sandbox.exec(sandboxID, command: "ls -1A \(quote(target))", timeout: 20, env: nil)
                    guard result.exitCode == 0 else { return ["error": result.stderr] }
                    let entries = result.stdout.split(separator: "\n").map(String.init)
                    return ["path": path, "entries": entries]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "read_file": { sandboxID, sandbox, args, _ in
                guard let path = args["path"]?.asString else { return ["error": "read_file requires 'path'"] }
                do {
                    let data = try await sandbox.readFile(sandboxID, path: path, maxBytes: 200_000)
                    return ["path": path, "content": String(decoding: data, as: UTF8.self)]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "write_file": { sandboxID, sandbox, args, _ in
                guard let path = args["path"]?.asString, let content = args["content"]?.asString else {
                    return ["error": "write_file requires 'path' and 'content'"]
                }
                do {
                    try await sandbox.writeFile(sandboxID, path: path, contents: Data(content.utf8))
                    return ["path": path, "bytes": content.utf8.count]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "run_shell": { sandboxID, sandbox, args, secretStore in
                guard let command = args["command"]?.asString else {
                    return ["error": "run_shell requires 'command'"]
                }
                let timeout = args["timeout"]?.asDouble ?? 120
                let useSecrets = args["use_secrets"]?.asStringArray ?? []
                let resolved = useSecrets.isEmpty ? [:] : ((try? await secretStore.resolveForExecution(names: useSecrets)) ?? [:])
                do {
                    let result = try await sandbox.exec(
                        sandboxID, command: command, timeout: timeout, env: resolved.isEmpty ? nil : resolved
                    )
                    let secretValues = Array(resolved.values)
                    let stdout = secretValues.isEmpty ? result.stdout : secretStore.mask(result.stdout, values: secretValues)
                    let stderr = secretValues.isEmpty ? result.stderr : secretStore.mask(result.stderr, values: secretValues)
                    return ["exit_code": Int(result.exitCode), "stdout": stdout, "stderr": stderr]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "screenshot": { sandboxID, sandbox, args, _ in
                guard let shot = await captureScreenshot(
                    sandboxID: sandboxID, sandbox: sandbox, filenameHint: args["filename"]?.asString
                ) else {
                    return ["error": "scrot failed or the captured file couldn't be read back"]
                }
                // "_base64" is popped by AgentRuntime before the tool result is
                // JSON-encoded into the chat transcript, and reused to attach
                // the image to the model's next message — mirrors Python's
                // `_usage` pop-off convention rather than duplicating the
                // whole image into the visible tool-result text.
                return ["filename": shot.filename, "bytes": shot.bytes, "_base64": shot.base64]
            },

            "list_windows": { sandboxID, sandbox, _, _ in
                do {
                    let result = try await sandbox.exec(sandboxID, command: "wmctrl -lG", timeout: 15, env: nil)
                    guard result.exitCode == 0 else { return ["error": result.stderr] }
                    let windows: [[String: Any]] = result.stdout.split(separator: "\n").compactMap { line in
                        let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
                        guard parts.count == 8 else { return nil }
                        return ["id": parts[0], "x": parts[2], "y": parts[3], "width": parts[4], "height": parts[5], "title": parts[7]]
                    }
                    return ["windows": windows]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "focus_window": { sandboxID, sandbox, args, _ in
                guard let title = args["title"]?.asString else { return ["error": "focus_window requires 'title'"] }
                do {
                    let result = try await sandbox.exec(sandboxID, command: "wmctrl -a \(quote(title))", timeout: 10, env: nil)
                    return result.exitCode == 0 ? ["ok": true] : ["error": result.stderr]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "open_app": { sandboxID, sandbox, args, _ in
                guard let app = args["app"]?.asString else { return ["error": "open_app requires 'app'"] }
                let command: String
                switch app {
                case "browser":
                    let target = args["url"]?.asString.map { quote($0) } ?? ""
                    command = "nohup chromium \(target) >/dev/null 2>&1 & disown"
                case "terminal":
                    command = "nohup xfce4-terminal --working-directory=/workspace >/dev/null 2>&1 & disown"
                case "files":
                    command = "nohup thunar /workspace >/dev/null 2>&1 & disown"
                default:
                    return ["error": "unknown app '\(app)', expected browser|terminal|files"]
                }
                do {
                    let result = try await sandbox.exec(sandboxID, command: command, timeout: 10, env: nil)
                    return result.exitCode == 0 ? ["ok": true, "app": app] : ["error": result.stderr]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "click": { sandboxID, sandbox, args, _ in
                guard let x = args["x"]?.asInt, let y = args["y"]?.asInt else {
                    return ["error": "click requires 'x' and 'y'"]
                }
                let button = args["button"]?.asInt ?? 1
                do {
                    // ai-click.py animates the pointer to (x, y) instead of
                    // warping it instantly, clicks, and flashes a transient
                    // "AI" badge at the click point — so a human watching
                    // over VNC can see, in real time, that this click came
                    // from the agent and where it landed, not just from a
                    // static screenshot after the fact.
                    let result = try await sandbox.exec(
                        sandboxID, command: "python3 /usr/local/bin/ai-click.py \(x) \(y) \(button)", timeout: 15, env: nil
                    )
                    guard result.exitCode == 0 else { return ["error": result.stderr] }
                    // Always attached, not left to the model to remember to
                    // ask for — see captureScreenshot's doc comment.
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["ok": true, "screenshot_error": "click succeeded but the verification screenshot failed"]
                    }
                    return ["ok": true, "screenshot": shot.filename, "_base64": shot.base64]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "type_text": { sandboxID, sandbox, args, _ in
                guard let text = args["text"]?.asString else { return ["error": "type_text requires 'text'"] }
                // Same absolute-vs-workspace-relative split as `screenshot`:
                // `writeFile` wants a path relative to /workspace; the shell
                // command that reads it back needs the absolute form.
                let relativeName = ".type_text_tmp"
                let absolutePath = "/workspace/\(relativeName)"
                do {
                    try await sandbox.writeFile(sandboxID, path: relativeName, contents: Data(text.utf8))
                    let result = try await sandbox.exec(
                        sandboxID,
                        command: "xdotool type --file \(quote(absolutePath)); rm -f \(quote(absolutePath))",
                        timeout: 15,
                        env: nil
                    )
                    guard result.exitCode == 0 else { return ["error": result.stderr] }
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["ok": true, "screenshot_error": "type_text succeeded but the verification screenshot failed"]
                    }
                    return ["ok": true, "screenshot": shot.filename, "_base64": shot.base64]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "press_key": { sandboxID, sandbox, args, _ in
                guard let key = args["key"]?.asString else { return ["error": "press_key requires 'key'"] }
                guard key.range(of: "^[A-Za-z0-9_+\\-]+$", options: .regularExpression) != nil else {
                    return ["error": "invalid key name '\(key)'"]
                }
                do {
                    let result = try await sandbox.exec(sandboxID, command: "xdotool key \(key)", timeout: 10, env: nil)
                    return result.exitCode == 0 ? ["ok": true] : ["error": result.stderr]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "scroll": { sandboxID, sandbox, args, _ in
                guard let direction = args["direction"]?.asString, ["up", "down"].contains(direction) else {
                    return ["error": "scroll requires direction: 'up' or 'down'"]
                }
                let amount = max(1, args["amount"]?.asInt ?? 5)
                // X11 mouse buttons 4/5 are the wheel-up/wheel-down events —
                // this is what xdotool uses to simulate scrolling, there's
                // no separate "scroll" primitive at the X11 level.
                let button = direction == "up" ? 4 : 5
                var command = ""
                if let x = args["x"]?.asInt, let y = args["y"]?.asInt {
                    command += "xdotool mousemove \(x) \(y) && "
                }
                command += "xdotool click --repeat \(amount) --delay 20 \(button)"
                do {
                    let result = try await sandbox.exec(sandboxID, command: command, timeout: 10, env: nil)
                    guard result.exitCode == 0 else { return ["error": result.stderr] }
                    // Same auto-verification as click/type_text — the whole
                    // point of scrolling is to bring something new into
                    // view, so the model needs to actually see the result.
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["ok": true, "screenshot_error": "scroll succeeded but the verification screenshot failed"]
                    }
                    return ["ok": true, "screenshot": shot.filename, "_base64": shot.base64]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },
        ]
    }
}

public extension AnyCodable {
    var asString: String? { value as? String }
    var asInt: Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }
    var asDouble: Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
    var asStringArray: [String]? { (value as? [Any])?.compactMap { $0 as? String } }
    var asBool: Bool? { value as? Bool }
}
