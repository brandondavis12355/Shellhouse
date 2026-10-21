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
    /// (`BotPersistence.swift`), not this package, so — the same shape as
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
        onRememberWithCheck: (@Sendable (String, String) async -> Bool)? = nil,
        onReplaceMemory: (@Sendable (String, String) async -> Bool)? = nil,
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
        onRequestCredentials: (@Sendable ([String: AnyCodable]) async -> [String: Any])? = nil,
        onGoalTool: (@Sendable (String, [String: AnyCodable]) async -> [String: Any])? = nil,
        onPostImage: (@Sendable (String, Data) async -> [String: Any])? = nil,
        /// (bot name or nil for yourself, action "view"/"append"/"replace", text)
        onBotInstructions: (@Sendable (String?, String, String?) async -> [String: Any])? = nil
    ) {
        var schemas = Self.buildSchemas()
        var executors = Self.buildExecutors()
        // Edit/read/search/job tools share one tracker per registry (one per run), so an edit is
        // checked against what this run actually read.
        executors.merge(WorkspaceTools.executors(tracker: FileReadTracker())) { _, new in new }
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
                // A note is a summary, not a copy of the message: ask for the point in a sentence or two.
                let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if ["asked ", "i asked", "we discussed", "i discussed", "today ", "just now", "i ran ", "i did ", "i checked", "the user said", "user asked"]
                    .contains(where: { lowered.hasPrefix($0) }) {
                    return ["error": "That reads as a log of what happened, not something to act on. Save only the lesson, as a rule for the right "
                        + "moment: \"When <situation>, <do this>\" (or the exact fact you'll need). If there is no such lesson, don't save anything."]
                }
                if text.count > Self.maxNoteCharacters {
                    return ["error": "That note is \(text.count) characters: too long. Don't save the message itself. Summarize only the "
                        + "parts you'll need again (the rule, the fact, the exact value or command) in one or two sentences under "
                        + "\(Self.maxNoteCharacters) characters, then call remember again with that."]
                }
                let check = arguments["check"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let saved: Bool
                if !check.isEmpty, let onRememberWithCheck { saved = await onRememberWithCheck(text, check) } else { saved = await onRemember(text) }
                guard saved else {
                    return ["error": "failed to save to disk — this wasn't actually remembered"]
                }
                return ["saved": true]
            }
        }
        if let onReplaceMemory {
            schemas.append(Self.replaceMemorySchema)
            executors["replace_memory"] = { _, _, arguments, _ in
                guard let id = arguments["id"]?.asString, !id.isEmpty,
                      let text = arguments["text"]?.asString, !text.isEmpty else {
                    return ["error": "replace_memory requires 'id' and non-empty 'text'"]
                }
                if text.count > Self.maxNoteCharacters {
                    return ["error": "That note is \(text.count) characters: too long. Summarize it under \(Self.maxNoteCharacters) characters, then call replace_memory again."]
                }
                guard await onReplaceMemory(id, text) else {
                    return ["error": "No note with that id. Use the id shown in your core memory."]
                }
                return ["replaced": true, "id": id]
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
        if let onRequestCredentials {
            schemas.append(Self.requestCredentialsSchema)
            executors["request_credentials"] = { _, _, arguments, _ in
                var arguments = arguments
                arguments["_kind"] = nil
                return await onRequestCredentials(arguments)
            }
            schemas.append(Self.requestLoginSchema)
            executors["request_login"] = { _, _, arguments, _ in
                var arguments = arguments
                arguments["_kind"] = AnyCodable("login")
                return await onRequestCredentials(arguments)
            }
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
        if let onBotInstructions {
            schemas.append(Self.getBotInstructionsSchema)
            schemas.append(Self.setBotInstructionsSchema)
            executors["get_bot_instructions"] = { _, _, arguments, _ in
                await onBotInstructions(arguments["bot"]?.asString, "view", nil)
            }
            executors["set_bot_instructions"] = { _, _, arguments, _ in
                let mode = arguments["mode"]?.asString ?? "append"
                guard ["append", "replace"].contains(mode) else { return ["error": "mode must be 'append' or 'replace'"] }
                guard let text = arguments["text"]?.asString else { return ["error": "set_bot_instructions requires 'text'"] }
                return await onBotInstructions(arguments["bot"]?.asString, mode, text)
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
        if let onPostImage {
            schemas.append(Self.postScreenshotSchema)
            executors["post_screenshot"] = { sandboxID, sandbox, arguments, _ in
                let caption = (arguments["caption"]?.asString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let data: Data
                if let path = arguments["path"]?.asString, !path.isEmpty {
                    guard let file = try? await sandbox.readFile(sandboxID, path: path, maxBytes: ChatImageStore.maxBytes) else {
                        return ["error": "Couldn't read '\(path)' on your VM. Check the path with list_files."]
                    }
                    data = file
                } else {
                    guard let shot = await ToolRegistry.captureScreenshotData(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["error": "The screenshot failed (scrot) or couldn't be read back."]
                    }
                    data = shot
                }
                guard ChatImageStore.imageExtension(of: data) != nil else {
                    return ["error": "That file isn't a PNG, JPEG, GIF or WebP image."]
                }
                return await onPostImage(caption, data)
            }
        }
        self.schemas = schemas
        self.executors = executors
    }

    private static var postScreenshotSchema: ToolSchema {
        ToolSchema(
            name: "post_screenshot",
            description: "Post an image into the chat you're working in, so your user (and the group) can see it: a "
                + "screenshot of your VM's screen right now, or an image file from your VM (a chart, a rendered page, a "
                + "design). Use it when seeing beats describing: a UI you built, a result, an error on screen. The caption "
                + "is posted with it.",
            parameters: [
                "type": "object",
                "properties": [
                    "caption": ["type": "string", "description": "One or two lines saying what the image shows."],
                    "path": ["type": "string", "description": "Optional: an image file on your VM (PNG, JPEG, GIF, WebP). Leave out to capture the screen."],
                ],
                "required": ["caption"],
            ]
        )
    }

    /// The screen as PNG bytes, full quality (for people to look at, unlike `captureScreenshot`'s copy for the model).
    private static func captureScreenshotData(sandboxID: String, sandbox: any SandboxProvider) async -> Data? {
        let filename = ".shellhouse/screens/shot-\(Int(Date().timeIntervalSince1970)).png"
        guard let captured = try? await sandbox.exec(sandboxID, command: GUICommand.wrap("mkdir -p /workspace/.shellhouse/screens && scrot \(shellQuote("/workspace/" + filename))"), timeout: 20, env: nil),
              captured.exitCode == 0 else { return nil }
        return try? await sandbox.readFile(sandboxID, path: filename, maxBytes: ChatImageStore.maxBytes)
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

    static let maxNoteCharacters = 300

    private static var rememberSchema: ToolSchema {
        ToolSchema(
            name: "remember",
            description: "Save one short note that will make you act correctly at the right moment next time: a rule shaped "
                + "\"When <situation>, <do this>\" (or a fact you'll need to act on), covering something your skills do NOT already say: "
                + "a correction or standing preference from the user, a fix that worked, a quirk of this VM, repo or tool, a needed command. "
                + "One or two sentences, never the message itself and never a log of what happened. It's shown to the user in this bot's "
                + "settings. Preferences land in your user block; a reusable command lands in procedures. "
                + "To change a note already in those blocks, call replace_memory with its id instead of saving a second copy. "
                + "Not for task-specific facts that only matter right now (use your reasoning or remember_task). "
                + "Up to 200 notes are kept (the least important are dropped first); check recall_memory first so you don't save a near-duplicate.",
            parameters: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "A rule to act on, e.g. \"When deploying, run make release from main.\" Under 300 characters; not a summary of what happened."],
                    "check": ["type": "string", "description": "Optional. When the note states a fact you can test (a file, a command, a branch), a read-only command that proves it: test -f/-d PATH, grep -q PATTERN FILE, command -v NAME, git rev-parse ..., ls PATH, joined with &&. Run it with run_shell first and see it exit 0. It is re-run when the note is recalled."],
                ],
                "required": ["text"],
            ]
        )
    }

    private static var replaceMemorySchema: ToolSchema {
        ToolSchema(
            name: "replace_memory",
            description: "Rewrite one note that is already in your core memory (the user or procedures block). "
                + "Pass the id shown next to that note. This changes that note; it does not add another.",
            parameters: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The id of the core note to rewrite."],
                    "text": ["type": "string", "description": "The new wording, under 300 characters."],
                ],
                "required": ["id", "text"],
            ]
        )
    }

    private static var recallMemorySchema: ToolSchema {
        ToolSchema(
            name: "recall_memory",
            description: "Search this bot's remembered notes, including ones that are not in the core blocks "
                + "of the system prompt. Use it when a fact might have been saved earlier and is not already "
                + "listed under User or Procedures.",
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

    private static var requestLoginSchema: ToolSchema {
        ToolSchema(
            name: "request_login",
            description: "Ask your user for a username and password for one service or website. Opens a secure sign-in "
                + "card in your 1:1 chat and waits. The password goes to the Mac's Keychain as <SERVICE>_PASSWORD and is "
                + "NEVER shown to you: type it with type_secret, or use it in run_shell's use_secrets. The username comes "
                + "back as plain text (and is saved as <SERVICE>_USERNAME). If they're already saved, your user can keep "
                + "them without retyping. Prefer this over request_credentials for any login.",
            parameters: [
                "type": "object",
                "properties": [
                    "service": ["type": "string", "description": "Short name, e.g. \"Jira\" or \"Vendor portal\"."],
                    "site": ["type": "string", "description": "The sign-in domain, e.g. jira.example.com, so your user can check it."],
                    "reason": ["type": "string", "description": "One line your user reads: what you'll do once signed in."],
                ],
                "required": ["service", "reason"],
            ]
        )
    }

    private static var requestCredentialsSchema: ToolSchema {
        ToolSchema(
            name: "request_credentials",
            description: "Ask your user for credentials you need (a password, API key, token, or a username to go "
                + "with it). Opens a secure form card in your 1:1 chat and waits for them. Secret fields are saved "
                + "to the Mac's Keychain under the name you give and are NEVER shown to you: use them with "
                + "run_shell's use_secrets (as $NAME) or type_secret. Non-secret fields (a username, an account "
                + "ID) come back as plain text. If a secret is already saved, your user can keep it without "
                + "retyping. Only ask for what the task needs.",
            parameters: [
                "type": "object",
                "properties": [
                    "reason": ["type": "string", "description": "One line your user reads: what the credentials are for."],
                    "fields": [
                        "type": "array",
                        "description": "1-5 fields to ask for.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Env-var style, e.g. GITHUB_TOKEN or SITE_PASSWORD (capital letters, digits, _)."],
                                "label": ["type": "string", "description": "What your user sees, e.g. \"GitHub personal access token\"."],
                                "secret": ["type": "boolean", "description": "true (default) for passwords, keys and tokens; false for a username or other non-secret."],
                            ],
                            "required": ["name", "label"],
                        ] as [String: Any],
                    ] as [String: Any],
                ],
                "required": ["reason", "fields"],
            ]
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
            description: "Ask or delegate something to another bot by name (see list_bots) and wait for its answer — "
                + "for when the user @mentions one asking you to coordinate with them, when something is "
                + "outside your own scope and one of them specializes in it, or when your task needs information "
                + "another bot has (its findings, files, results). The result includes checked: true only when that "
                + "bot actually ran tools. checked: false means it answered from memory, was busy, or this question "
                + "was already asked — do not save that answer as a fact. A bot that is answering you may message "
                + "one further bot; that bot cannot pass the question on. If it's busy, it answers from what it already "
                + "knows, without running anything. This happens in the background: "
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

    private static var getBotInstructionsSchema: ToolSchema {
        ToolSchema(
            name: "get_bot_instructions",
            description: "Read a bot's custom instructions: the part of its system prompt its user added (its role, how it should "
                + "work). Leave out 'bot' for your own. Read before changing them.",
            parameters: ["type": "object", "properties": [
                "bot": ["type": "string", "description": "The bot's name; omit for yourself."],
            ], "required": []]
        )
    }

    private static var setBotInstructionsSchema: ToolSchema {
        ToolSchema(
            name: "set_bot_instructions",
            description: "Change a bot's custom instructions (yours, or another bot's), for a lasting change to its role or how it "
                + "works — not for one task (send that with message_bot). The user approves every change. 'append' adds a "
                + "paragraph; 'replace' rewrites them all (read them first with get_bot_instructions and keep what still applies). "
                + "The built-in rules and tools are not part of this and can't be changed.",
            parameters: ["type": "object", "properties": [
                "bot": ["type": "string", "description": "The bot's name; omit for yourself."],
                "mode": ["type": "string", "enum": ["append", "replace"], "description": "append (default) or replace."],
                "text": ["type": "string", "description": "The paragraph to add, or the full new instructions. Plain prose, no secrets."],
            ], "required": ["text"]]
        )
    }

    private static var createBotSchema: ToolSchema {
        ToolSchema(
            name: "create_bot",
            description: "Create a brand-new bot with its own sandbox — for when something is outside your "
                + "own scope AND no existing bot (see list_bots) specializes in it either, so you're "
                + "recruiting a specialist rather than handling it yourself. The new bot gets your local model, "
                + "boots its own sandbox in the background (message_bot waits for it), and starts with no "
                + "conversation, no memory and none of your files, so give it a "
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
                    "steps": ["type": "array", "items": ["type": "string"], "description": "2-8 concrete steps, in order."],
                    "depends_on": ["type": "array", "description": "Which steps must wait for others, by step number (1 = first). "
                        + "E.g. tests and the CLI both need the game logic in step 2: [{\"step\": 3, \"after\": [2]}, {\"step\": 4, \"after\": [2]}]. "
                        + "Leave out steps that can start right away. A step can only wait on earlier steps.",
                                   "items": ["type": "object", "properties": [
                                       "step": ["type": "integer"],
                                       "after": ["type": "array", "items": ["type": "integer"]],
                                   ] as [String: Any], "required": ["step", "after"]] as [String: Any]] as [String: Any],
                    "validator": str("Optional: the member who checks submitted steps and marks them done, if not you (e.g. the tester when you only coordinate).")],
                   required: ["title", "steps"]),
            schema("add_goal_step", "Append a step to the checklist. Start its text with the member who should do it (\"Bugbot: …\"). Any member can add a step; the owner can edit or remove it.",
                   ["text": str("The new step."),
                    "after": ["type": "array", "items": ["type": "integer"], "description": "Optional: step numbers this one must wait for."]],
                   required: ["text"]),
            schema("edit_goal_step",
                   "Goal owner only: change the plan. Reword a step, reassign it, change what it waits on, reopen a finished one, or remove one. Members: ask the owner instead.",
                   ["step_id": str("Step id from get_goal / the goal block."),
                    "text": str("Optional: the new wording."),
                    "assignee": str("Optional: who should do it; empty string to unassign."),
                    "after": ["type": "array", "items": ["type": "integer"], "description": "Optional: replace what it waits on (step numbers; [] for nothing)."],
                    "reopen": ["type": "boolean", "description": "Optional: put a done or blocked step back to open."],
                    "remove": ["type": "boolean", "description": "Optional: delete the step."]],
                   required: ["step_id"]),
            schema("update_goal_step",
                   "Update a checklist step. Set 'inProgress' when you take it on, 'blocked' (with the reason as evidence) if you can't proceed, or 'done' — done REQUIRES evidence: what you ran or checked in THIS turn and what it showed. If you are NOT the goal owner, 'done' only SUBMITS the step for validation (shown as [?]); the goal owner re-checks it with their own tools and is the only one who can mark it truly done. Only the owner's validated completions count as progress.",
                   ["step_id": str("Step id from get_goal / the goal block."),
                    "status": ["type": "string", "enum": ["inProgress", "done", "blocked"]],
                    "evidence": str("Required for done: what you did/checked and the result."),
                    "assignee": str("Optional: who is on it (usually you).")],
                   required: ["step_id", "status"]),
            schema("propose_goal_complete",
                   "Goal owner only: wrap up the goal with a short summary of the outcome. When every step is done, the goal closes at once (it also closes by itself when the last step is validated). When some steps are blocked, the user confirms the partial finish.",
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
        filenameHint: String? = nil,
        clicked: Bool = false
    ) async -> (filename: String, bytes: Int, base64: String, changed: Double?)? {
        let filename = sanitizeFilename(filenameHint) ?? "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        let absolutePath = "/workspace/\(filename)"
        // The pointer's position comes back with the capture, to be drawn into the copy the model sees (scrot leaves it out).
        guard let captured = try? await sandbox.exec(sandboxID, command: GUICommand.wrap("scrot \(shellQuote(absolutePath)) && { xdotool getmouselocation --shell 2>/dev/null || true; }"), timeout: 20, env: nil),
              captured.exitCode == 0,
              let data = try? await sandbox.readFile(sandboxID, path: filename, maxBytes: 10_000_000) else {
            return nil
        }
        let changed = ScreenMemory.shared.record(data, for: sandboxID)
        let marked = ScreenOverlay.annotate(data, pointer: pointerPosition(in: captured.stdout), clicked: clicked)
        return (filename, data.count, compressedForModel(marked).base64EncodedString(), changed)
    }

    /// One page operation (see `BrowserControl`): run the script in the VM, read its one line of JSON, and turn its error codes into advice.
    private static func runBrowser(_ operation: BrowserControl.Operation, _ args: [String], sandboxID: String, sandbox: any SandboxProvider) async -> [String: Any] {
        guard let result = try? await sandbox.exec(sandboxID, command: BrowserControl.command(operation, args), timeout: 40, env: nil) else {
            return ["error": "could not reach the VM to control the browser"]
        }
        guard let line = result.stdout.split(separator: "\n").last, let data = String(line).data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "the browser tool printed nothing usable", "detail": String(result.stderr.suffix(300))]
        }
        switch object["error"] as? String {
        case "browser_not_controllable"?:
            object["error"] = "The browser can't be controlled: it was started some other way, or isn't running. Call open_app with the browser and a url; that restarts it so these tools work. For anything outside the browser, use screenshot and click."
        case "no_match"?:
            object["hint"] = "Try fewer or different words (the text on the element), or find_on_page to list what the page has. If it truly isn't labelled, take a screenshot and use click."
        case "no_page"?:
            object["error"] = "The browser has no page open. Call open_app with the browser and a url."
        default: break
        }
        return object
    }

    /// `X=…` and `Y=…` lines of `xdotool getmouselocation --shell`.
    static func pointerPosition(in output: String) -> (x: Int, y: Int)? {
        var x: Int?, y: Int?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("X=") { x = Int(line.dropFirst(2)) } else if line.hasPrefix("Y=") { y = Int(line.dropFirst(2)) }
        }
        guard let x, let y else { return nil }
        return (x, y)
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
                description: "Returns the text of one file in the sandbox, a page at a time: about 12,000 characters (usually the whole file) from line `offset` on, with start_line, end_line, total_lines and next_offset when there is more. Read a file before editing it with edit_file. To find files or text, use find_files or search_files. Paths are relative to /workspace unless absolute. An error means the path is wrong or unreadable: list the parent directory before retrying.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "offset": ["type": "integer", "description": "1-based line to start at (default 1). Use next_offset from the previous page to continue."],
                        "limit": ["type": "integer", "description": "Optional maximum number of lines."],
                    ],
                    "required": ["path"],
                ]
            ),
            ToolSchema(
                name: "write_file",
                description: "Creates a file, or replaces the ENTIRE contents of one, in /workspace. To change part of an existing file, use edit_file instead. .py, .json, .sh and .yaml files are syntax-checked: a change that breaks a file which parsed before is refused and the file left unchanged. Returns ok or an error naming the problem.",
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
                description: "Runs one bash command in YOUR OWN Linux VM (user `box`, Debian; `sudo` works only if the user enabled it, test with `sudo -n true`) and returns {exit_code, stdout, stderr}. Check the OUTPUT, not just exit_code: a chained command (`a; echo exit=$?`) can exit 0 around a failure. Prefer one simple command per call, `command -v <tool>` to test for a program, absolute paths, and `| head`/`| tail` for big output (long output is cut in the middle). Do not repeat a command whose result you already have; if it printed nothing or failed, change the approach. Package installs: `sudo apt-get update` first if lookups come back empty.",
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
                        "background": [
                            "type": "boolean",
                            "description": "Start it and return at once with a job_id, for builds, installs, servers or anything slower than about 2 minutes. Follow it with check_job / stop_job. Not with use_secrets.",
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
                description: "Launch an application on the sandbox desktop. To open another web page, call this again with browser and that url: it opens in the same browser window (more reliable than typing into the address bar). After opening, take a screenshot before you click anything.",
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
                description: "Click. With x and y: move the mouse to those screen coordinates and click. Without them: click where the pointer is now (use move_mouse first, check the screenshot, then click). Screenshots have a ruler (numbers every 100 px) and an arrow cursor at the pointer, with orange ripple rings after a click, so you can read positions and see where a click landed. A click result also says where the pointer ended and which window is under it. Take a screenshot first; coordinates from memory or an older screenshot are often wrong.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "x": ["type": "integer"],
                        "y": ["type": "integer"],
                        "button": ["type": "integer", "description": "1=left, 2=middle, 3=right. Default 1."],
                    ],
                    "required": [],
                ]
            ),
            ToolSchema(
                name: "find_on_page",
                description: "List the links, buttons and fields in the browser page whose visible text matches (best match first), with their position. Use it to see what is on a page and to check a name before click_text. Needs the browser opened with open_app.",
                parameters: ["type": "object", "properties": ["text": ["type": "string", "description": "Words on the element, e.g. Reports or Sign in."]], "required": ["text"]]
            ),
            ToolSchema(
                name: "click_text",
                description: "Click a link, button or field in the browser page by its visible text (e.g. \"Reports\"), with real mouse events at its centre. No coordinates to get wrong: prefer this to click for anything on a web page. Reports the page address after, and whether it changed. Scrolls to the element if needed. If several match, index picks one (0 is the best match).",
                parameters: ["type": "object", "properties": ["text": ["type": "string"], "index": ["type": "integer", "description": "Which match, from find_on_page. Default 0."]], "required": ["text"]]
            ),
            ToolSchema(
                name: "fill_field",
                description: "Put text into a field of the browser page, found by its label or placeholder (e.g. \"Serial or asset tag\"), replacing what is there. With submit true it then presses Enter. Not for passwords: click the field with click_text, then use type_secret.",
                parameters: ["type": "object", "properties": ["label": ["type": "string"], "text": ["type": "string"], "submit": ["type": "boolean", "description": "Press Enter afterwards (to search or sign in). Default false."]], "required": ["label", "text"]]
            ),
            ToolSchema(
                name: "page_text",
                description: "The text of the browser page (title, address and visible text), up to max_chars. Cheaper and exact compared with reading a screenshot: use it to read results, tables and messages.",
                parameters: ["type": "object", "properties": ["max_chars": ["type": "integer", "description": "Default 6000, at most 20000."]]]
            ),
            ToolSchema(
                name: "move_mouse",
                description: "Move the mouse pointer to screen coordinates without clicking, and return a screenshot with the cursor drawn at the pointer. Use it to check that the pointer is on the right thing (a field, a button), correct it if not, then click with no coordinates.",
                parameters: [
                    "type": "object",
                    "properties": ["x": ["type": "integer"], "y": ["type": "integer"]],
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
                name: "type_secret",
                description: "Type a saved secret (e.g. a password from request_credentials) into a desktop window "
                    + "without you ever seeing it. Focuses the window whose title contains `window` first, then "
                    + "types into its focused field. Click the password field before calling this. No screenshot "
                    + "comes back; follow with press_key('Return') to submit. Always asks your user to approve.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "The secret's name, e.g. SITE_PASSWORD."],
                        "window": ["type": "string", "description": "Part of the target window's title, e.g. 'Sign in - Chromium'."],
                    ],
                    "required": ["name", "window"],
                ]
            ),
            ToolSchema(
                name: "press_key",
                description: "Press a key or key combo (xdotool syntax, e.g. 'Return', 'ctrl+l'). Returns a screenshot of the result.",
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
            ToolSchema(
                name: "edit_file",
                description: "Changes part of a file: replaces old_text with new_text (or pass edits to make several changes in one call). old_text must match the file exactly once (indentation differences are tolerated), so include a few surrounding lines. Read the file with read_file first; the edit is refused if you haven't, or if it changed since. Returns a numbered snippet of the result. Syntax-checked like write_file. To create or rewrite a whole file, use write_file.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "old_text": ["type": "string", "description": "Exact text currently in the file (no line numbers)."],
                        "new_text": ["type": "string", "description": "What to put in its place (empty to delete it)."],
                        "replace_all": ["type": "boolean", "description": "Replace every match instead of requiring exactly one."],
                        "edits": ["type": "array", "description": "Several changes to the same file in ONE call, applied in order and all-or-nothing: each item {old_text, new_text}. Prefer this over repeated edit_file calls.",
                                  "items": ["type": "object", "properties": ["old_text": ["type": "string"], "new_text": ["type": "string"]], "required": ["old_text", "new_text"]]],
                    ],
                    "required": ["path"],
                ]
            ),
            ToolSchema(
                name: "search_files",
                description: "Searches file contents under /workspace (grep -E, extended regex) and returns up to max_results matches as \"file:line: text\". Skips .git, node_modules and binary files. No approval needed. If there are too many matches, narrow the pattern, path or file_glob.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "pattern": ["type": "string", "description": "Extended regular expression, e.g. \"def (load|save)_\"."],
                        "path": ["type": "string", "description": "Folder or file inside /workspace (default: all of it)."],
                        "file_glob": ["type": "string", "description": "Only files whose name matches, e.g. \"*.py\"."],
                        "max_results": ["type": "integer", "description": "Default 50, at most 200."],
                    ],
                    "required": ["pattern"],
                ]
            ),
            ToolSchema(
                name: "find_files",
                description: "Lists files under /workspace whose name matches a glob (e.g. \"*.csv\", \"report*\"), sorted, up to 200. Skips .git and node_modules. No approval needed.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "pattern": ["type": "string", "description": "File-name glob."],
                        "path": ["type": "string", "description": "Folder inside /workspace (default: all of it)."],
                    ],
                    "required": ["pattern"],
                ]
            ),
            ToolSchema(
                name: "check_job",
                description: "Status of a background job started with run_shell(background: true): running or finished (with exit_code), and the last lines of its output. To wait for it, pass wait_seconds (up to 110) and call again if it's still running; don't poll with sleep commands. Its full output is in the log file it names.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "job_id": ["type": "string"],
                        "tail_lines": ["type": "integer", "description": "How many output lines to return (default 40)."],
                        "wait_seconds": ["type": "integer", "description": "Wait up to this many seconds (max 110) for the job to finish before answering, instead of checking again and again."],
                    ],
                    "required": ["job_id"],
                ]
            ),
            ToolSchema(
                name: "stop_job",
                description: "Stops a background job started with run_shell(background: true).",
                parameters: [
                    "type": "object",
                    "properties": ["job_id": ["type": "string"]],
                    "required": ["job_id"],
                ]
            ),
        ]
    }

    // MARK: - Executors

    private static func buildExecutors() -> [String: Executor] {
        [
            "list_files": { sandboxID, sandbox, args, _ in
                let path = args["path"]?.asString ?? ""
                // Relative to /workspace; an absolute path ("/workspace/repo") is taken as is, not doubled.
                let target = (path.isEmpty || path == ".") ? "/workspace" : (path.hasPrefix("/") ? path : "/workspace/\(path)")
                do {
                    let result = try await sandbox.exec(sandboxID, command: "ls -1A \(shellQuote(target))", timeout: 20, env: nil)
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
                if args["background"]?.asBool == true {
                    guard useSecrets.isEmpty else {
                        return ["error": "background jobs can't use secrets (their output isn't masked); run it in the foreground"]
                    }
                    let jobID = WorkspaceTools.newJobID()
                    do {
                        let started = try await sandbox.exec(sandboxID, command: WorkspaceTools.backgroundCommand(command, jobID: jobID), timeout: 20, env: nil)
                        guard started.exitCode == 0 else { return ["error": started.stderr.isEmpty ? "could not start the job" : started.stderr] }
                        return ["job_id": jobID, "started": true, "log": "/workspace/.shellhouse/jobs/\(jobID)/log",
                                "note": "Running in the background. Use check_job to see progress and stop_job to stop it."]
                    } catch {
                        return ["error": error.localizedDescription]
                    }
                }
                if let reserved = useSecrets.first(where: SecretStore.isAppInternal) {
                    return ["error": "'\(reserved)' is one of the app's own credentials and can't be used by a tool."]
                }
                let resolved = useSecrets.isEmpty ? [:] : ((try? await secretStore.resolveForExecution(names: useSecrets)) ?? [:])
                do {
                    let result = try await sandbox.exec(
                        sandboxID, command: command, timeout: timeout, env: resolved.isEmpty ? nil : resolved
                    )
                    let secretValues = Array(resolved.values)
                    // Masked even without use_secrets: a CLI logged in on its own (gh, a .env file) can print one too.
                    let stdout = secretStore.mask(result.stdout, values: secretValues)
                    let stderr = secretStore.mask(result.stderr, values: secretValues)
                    var out: [String: Any] = ["exit_code": Int(result.exitCode), "stdout": stdout, "stderr": stderr]
                    if result.exitCode == 124, stderr.hasPrefix("Timed out") {
                        out["hint"] = "The command may still be running, and its output is lost. For anything this slow, use "
                            + "run_shell with background: true, then check_job."
                    }
                    // Too long to show in full: keep all of it in a file the model can search or page through.
                    if let path = await WorkspaceTools.spill(stdout, field: "stdout", sandboxID: sandboxID, sandbox: sandbox) {
                        out["full_stdout_path"] = path
                    }
                    if let path = await WorkspaceTools.spill(stderr, field: "stderr", sandboxID: sandboxID, sandbox: sandbox) {
                        out["full_stderr_path"] = path
                    }
                    return out
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
                    let result = try await sandbox.exec(sandboxID, command: GUICommand.wrap("wmctrl -lG"), timeout: 15, env: nil)
                    guard result.exitCode == 0 else { return ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode)] }
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
                    let result = try await sandbox.exec(sandboxID, command: GUICommand.wrap("wmctrl -a \(shellQuote(title))"), timeout: 10, env: nil)
                    return result.exitCode == 0 ? ["ok": true] : ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode)]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "open_app": { sandboxID, sandbox, args, _ in
                guard let app = args["app"]?.asString else { return ["error": "open_app requires 'app'"] }
                let command: String
                switch app {
                case "browser":
                    let target = args["url"]?.asString.map { shellQuote($0) } ?? ""
                    command = GUICommand.openApp(
                        process: "chromium", launch: "chromium \(BrowserControl.launchFlags) \(target)", once: args["url"]?.asString,
                        controllable: "curl -sf -m 2 http://127.0.0.1:\(BrowserControl.port)/json/version >/dev/null")
                case "terminal":
                    command = GUICommand.openApp(process: "xfce4-terminal", launch: "xfce4-terminal --working-directory=/workspace")
                case "files":
                    command = GUICommand.openApp(process: "thunar", launch: "thunar /workspace")
                default:
                    return ["error": "unknown app '\(app)', expected browser|terminal|files"]
                }
                do {
                    let result = try await sandbox.exec(sandboxID, command: command, timeout: 20, env: nil)
                    if result.exitCode == Int32(GUICommand.alreadyOpenExit) { return ["ok": true, "app": app, "already_open": true, "note": GUICommand.alreadyOpenNote] }
                    return result.exitCode == 0 ? ["ok": true, "app": app] : ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode, app: app)]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "find_on_page": { sandboxID, sandbox, args, _ in
                guard let text = args["text"]?.asString, !text.isEmpty else { return ["error": "find_on_page requires 'text'"] }
                return await runBrowser(.find, [text], sandboxID: sandboxID, sandbox: sandbox)
            },

            "click_text": { sandboxID, sandbox, args, _ in
                guard let text = args["text"]?.asString, !text.isEmpty else { return ["error": "click_text requires 'text'"] }
                // The "before" screenshot is taken here, so the bot need not take one first.
                let before = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox)
                var result = await runBrowser(.click, [text, String(args["index"]?.asInt ?? 0)], sandboxID: sandboxID, sandbox: sandbox)
                if let before { result["before_screenshot"] = before.filename }
                guard result["error"] == nil else { return result }
                if let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox, clicked: true) {
                    result["screenshot"] = shot.filename; result["_base64"] = shot.base64
                    for (k, v) in GUICommand.reaction(shot.changed, after: "click") where k == "screen_changed" { result[k] = v }
                }
                return result
            },

            "fill_field": { sandboxID, sandbox, args, _ in
                guard let label = args["label"]?.asString, !label.isEmpty, let text = args["text"]?.asString else {
                    return ["error": "fill_field requires 'label' and 'text'"]
                }
                let before = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox)
                var result = await runBrowser(.fill, [label, text] + ((args["submit"]?.asBool ?? false) ? ["submit"] : []), sandboxID: sandboxID, sandbox: sandbox)
                if let before { result["before_screenshot"] = before.filename }
                guard result["error"] == nil else { return result }
                if let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) {
                    result["screenshot"] = shot.filename; result["_base64"] = shot.base64
                }
                return result
            },

            "page_text": { sandboxID, sandbox, args, _ in
                await runBrowser(.text, [String(min(max(args["max_chars"]?.asInt ?? 6000, 500), 20_000))], sandboxID: sandboxID, sandbox: sandbox)
            },

            "move_mouse": { sandboxID, sandbox, args, _ in
                guard let x = args["x"]?.asInt, let y = args["y"]?.asInt else { return ["error": "move_mouse requires 'x' and 'y'"] }
                do {
                    let result = try await sandbox.exec(sandboxID, command: GUICommand.wrap("xdotool mousemove \(x) \(y)"), timeout: 10, env: nil)
                    guard result.exitCode == 0 else { return ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode)] }
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["ok": true, "screenshot_error": "the pointer moved but the screenshot failed"]
                    }
                    return ["ok": true, "pointer": ["x": x, "y": y], "screenshot": shot.filename, "_base64": shot.base64]
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "click": { sandboxID, sandbox, args, _ in
                let button = args["button"]?.asInt ?? 1
                let at = (args["x"]?.asInt).flatMap { x in (args["y"]?.asInt).map { (x, $0) } }
                if args["x"] != nil || args["y"] != nil, at == nil { return ["error": "click needs both 'x' and 'y', or neither (to click where the pointer is)"] }
                do {
                    // ai-click.py animates the pointer to (x, y) instead of
                    // warping it instantly, clicks, and flashes a transient
                    // "AI" badge at the click point — so a human watching
                    // over VNC can see, in real time, that this click came
                    // from the agent and where it landed, not just from a
                    // static screenshot after the fact.
                    let command = at.map { GUICommand.click(x: $0.0, y: $0.1, button: button) }
                        ?? GUICommand.wrap("xdotool mousedown \(button); sleep 0.08; xdotool mouseup \(button); xdotool getmouselocation --shell")
                    let result = try await sandbox.exec(sandboxID, command: command, timeout: 20, env: nil)
                    guard result.exitCode == 0 else { return ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode)] }
                    // Always attached, not left to the model to remember to
                    // ask for — see captureScreenshot's doc comment.
                    // Where the pointer really ended and what is under it, so a click that missed shows in the result.
                    var report: [String: Any] = [:]
                    if let data = result.stdout.split(separator: "\n").last.flatMap({ $0.data(using: .utf8) }),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let pointer = parsed["pointer"] { report["pointer"] = pointer }
                        if let window = parsed["window"] as? String, !window.isEmpty { report["window_under_pointer"] = window }
                        if parsed["landed"] as? Bool == false {
                            report["warning"] = "The pointer did not end where you aimed; the click may have hit something else. Check the screenshot."
                        }
                    }
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox, clicked: true) else {
                        return report.merging(["ok": true, "screenshot_error": "click succeeded but the verification screenshot failed"]) { a, _ in a }
                    }
                    return report.merging(["ok": true, "screenshot": shot.filename, "_base64": shot.base64]) { a, _ in a }
                        .merging(GUICommand.reaction(shot.changed, after: "click")) { a, _ in a }
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
                        command: GUICommand.wrap("xdotool type --file \(shellQuote(absolutePath)); rm -f \(shellQuote(absolutePath))"),
                        timeout: 15,
                        env: nil
                    )
                    guard result.exitCode == 0 else { return ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode)] }
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["ok": true, "screenshot_error": "type_text succeeded but the verification screenshot failed"]
                    }
                    return ["ok": true, "screenshot": shot.filename, "_base64": shot.base64]
                        .merging(GUICommand.reaction(shot.changed, after: "type_text")) { a, _ in a }
                } catch {
                    return ["error": error.localizedDescription]
                }
            },

            "type_secret": { sandboxID, sandbox, args, secretStore in
                guard let name = args["name"]?.asString, let window = args["window"]?.asString, !window.isEmpty else {
                    return ["error": "type_secret requires 'name' and 'window'"]
                }
                guard !SecretStore.isAppInternal(name) else {
                    return ["error": "'\(name)' is one of the app's own credentials and can't be typed by a tool."]
                }
                guard let value = (try? await secretStore.resolveForExecution(names: [name]))?[name] else {
                    return ["error": "no saved secret named '\(name)'. Ask for it with request_credentials."]
                }
                // The value reaches xdotool on stdin from an env var: never in a command line, a file, or this result.
                let command = "wmctrl -a \(shellQuote(window)) || { echo 'no window matching that title' >&2; exit 3; }; "
                    + "sleep 0.3; active=$(xdotool getactivewindow getwindowname 2>/dev/null); shopt -s nocasematch; "
                    + "case \"$active\" in *\(shellQuote(window))*) ;; "
                    + "*) echo \"focused window is '$active', not the one asked for\" >&2; exit 4;; esac; "
                    + "printf %s \"$SHELLHOUSE_SECRET_VALUE\" | xdotool type --clearmodifiers --delay 25 --file -"
                do {
                    let result = try await sandbox.exec(sandboxID, command: GUICommand.wrap(command), timeout: 30, env: ["SHELLHOUSE_SECRET_VALUE": value])
                    guard result.exitCode == 0 else {
                        return ["error": secretStore.mask(result.stderr, values: [value]).trimmingCharacters(in: .whitespacesAndNewlines)]
                    }
                    return ["ok": true, "typed": name,
                            "note": "Typed. No screenshot is returned so the value can't be seen; press_key('Return') to submit, then take a screenshot."]
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
                    let result = try await sandbox.exec(sandboxID, command: GUICommand.wrap("xdotool key \(key); sleep 0.5"), timeout: 10, env: nil)
                    guard result.exitCode == 0 else { return ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode)] }
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["ok": true, "screenshot_error": "the key was pressed but the verification screenshot failed; take a screenshot"]
                    }
                    return ["ok": true, "screenshot": shot.filename, "_base64": shot.base64]
                        .merging(GUICommand.reaction(shot.changed, after: "press_key")) { a, _ in a }
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
                    let result = try await sandbox.exec(sandboxID, command: GUICommand.wrap(command), timeout: 10, env: nil)
                    guard result.exitCode == 0 else { return ["error": GUICommand.failure(result.stderr, exitCode: result.exitCode)] }
                    // Same auto-verification as click/type_text — the whole
                    // point of scrolling is to bring something new into
                    // view, so the model needs to actually see the result.
                    guard let shot = await captureScreenshot(sandboxID: sandboxID, sandbox: sandbox) else {
                        return ["ok": true, "screenshot_error": "scroll succeeded but the verification screenshot failed"]
                    }
                    return ["ok": true, "screenshot": shot.filename, "_base64": shot.base64]
                        .merging(GUICommand.reaction(shot.changed, after: "scroll")) { a, _ in a }
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
