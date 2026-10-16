import Foundation
import Observation
import UniformTypeIdentifiers
import AgentCore
import AgentUI

struct DisplayMessage: Identifiable {
    let id = UUID()
    let role: ChatMessage.Role
    /// `var`, not `let` — a streaming assistant reply mutates this in place
    /// turn by turn (see `Bot.streamingIndex`/`handleEvent`'s
    /// `.messageDelta` case) so the bubble fills in live instead of
    /// appearing all at once, while keeping the same `id` so SwiftUI
    /// updates the existing bubble rather than inserting a new one.
    var text: String
    /// Filenames attached alongside this message (see
    /// `Bot.pendingAttachments`/`queueMessage`) — shown as small chips
    /// under the bubble by `MessageBubble`. Display-only: an image
    /// attachment's actual bytes travel to the model via `ChatMessage
    /// .images`, and a non-image file's via the sandbox write `queueMessage`
    /// does before sending, not through this list.
    var attachmentNames: [String] = []
    /// Marks this as a "Messaged <name>…" notice (see `Bot.delegateToBot`)
    /// instead of normal chat text — `TranscriptView` renders it as a
    /// tappable pill that opens the read-only thread with that bot rather
    /// than a text bubble. `nil` for every ordinary message.
    var interBotPeerID: String?
    var interBotPeerName: String?
    var timestamp: Date = Date()
    /// Set only for a `role == .tool` message — which tool produced it,
    /// so `MessageBubble` can show a collapsed "Ran <name>…" row instead
    /// of the full raw JSON result inline. See `ChatMessage.toolName`.
    var toolName: String?
    /// Set only for the `finish_task` summary — a near-duplicate recap of
    /// whatever the model already said just before it, so `MessageBubble`
    /// collapses it by default too. See `ChatMessage.isTaskSummary`.
    var isTaskSummary: Bool = false
    /// Images a bot posted with this message (`post_screenshot`), as `ChatImageStore` ids.
    var imageIDs: [String] = []
}

/// Which run currently holds a bot's run lock — `pendingApproval` is a
/// single shared slot (see `Bot.isBusy`'s doc comment: only one of a
/// bot's own chat, a delegation, or a group turn ever holds the lock at
/// once), so this is what lets `Bot.stop()` tell "an approval this
/// bot's own chat raised" apart from "an approval some unrelated
/// delegation/group turn raised, which just happens to be visible in
/// the same UI slot right now" — it must only ever resolve the former.
enum RunLockOwner: Equatable {
    case ownChat
    /// Wraps `runIsolatedTask`'s own `debugContext` label (e.g.
    /// `"group: VirusProgramming"`, `"delegated from Tai Lung"`) —
    /// not used for the ownership comparison itself, just carried along
    /// so it's available if this ever needs surfacing somewhere.
    case isolated(String)
}

struct PendingApproval: Identifiable {
    let approval: Approval
    let continuation: CheckedContinuation<AgentRuntime.ApprovalDecision, Never>
    let owner: RunLockOwner
    var id: String { approval.id }
}

/// Lets a tool closure built before its `AgentRuntime` ask that runtime about itself later.
final class RuntimeProbe: @unchecked Sendable {
    weak var runtime: AgentRuntime?
}

/// A bot waiting on its user for credentials (`request_credentials`). Shown as a form card in the
/// bot's 1:1 chat; `continuation` gets the typed values (nil = declined), which go straight to the
/// Keychain and never back to the model.
struct PendingCredentialRequest: Identifiable {
    let id = UUID()
    let request: CredentialRequest
    /// Secret names already in the Keychain, which the user can keep instead of retyping.
    let savedNames: Set<String>
    /// The run had read untrusted content (a web page, a friend's message) when it asked.
    let untrusted: Bool
    let continuation: CheckedContinuation<[String: String]?, Never>
}

/// One independent chat: its own sandbox (own persistent Linux container —
/// see `docker_backend.py`'s per-task-container support), own model/vision/
/// skills/budgets, own transcript, own `AgentRuntime`. The sidebar in
/// `ContentView` holds a list of these; everything that used to be
/// `ContentView`'s own `@State` before there was more than one conversation
/// lives here instead, so N bots don't share state that should be
/// independent.
///
/// `RunShellPermissions` is the one exception, deliberately NOT owned here —
/// it's injected from `ContentView` and shared across every `Bot`, since
/// "always allow this session" is meant to mean "for this app launch,"
/// not "for this one bot."
/// `@MainActor` because every mutation happens from SwiftUI/Task-on-MainActor
/// context anyway (this is a UI-bound model, not background compute); marking
/// it explicitly means the compiler enforces that rather than it being
/// incidental. `@unchecked Sendable` is what lets `[weak self]` be captured
/// in `AgentRuntime`'s `@Sendable` callback closures — safe here because
/// `@MainActor` isolation is exactly what makes access to this object safe
/// across those closure calls in the first place; same pattern already used
/// for `SSHTunnel`/`OllamaManager`.
@MainActor
@Observable
final class Bot: Identifiable, @unchecked Sendable {
    let id: String
    var name: String
    var colorHex: String
    /// Which `AvatarStyle` (see `BotAvatar.swift`) this bot's sidebar/header
    /// icon renders as. Purely cosmetic, one of 8 fixed options.
    var avatarStyle: Int = 0
    /// Short role/description shown next to the name (sidebar row and the
    /// chat header), matching the reference app's per-bot role badge.
    /// Purely cosmetic — nothing reads this for behavior.
    var tagline: String
    /// As a goal owner, whether this bot re-checks members' submitted steps itself. Off for a manager that only
    /// coordinates: a validator member does the checking (see `GroupGoal.validatorName`).
    var checksGoalWorkItself = true
    /// Sidebar section header this bot is filed under (e.g. "General").
    /// Organizational only — bots in the same group don't share anything;
    /// there's no multi-bot group-chat mechanism behind this.
    var group: String

    var state: ComputerPanel.State = .noSandbox
    var status = "Starting…"
    var displayMessages: [DisplayMessage] = []
    var input = ""
    /// A file or image picked (via the paperclip button) but not sent yet —
    /// cleared into a real message's `images`/attached-file note the moment
    /// `submitInput` actually sends it. `isImage` decides whether it travels
    /// to the model as a vision image or gets written into the sandbox's
    /// `/workspace` for the agent to read by path.
    struct PendingAttachment: Identifiable {
        let id = UUID()
        let url: URL
        let isImage: Bool
    }
    var pendingAttachments: [PendingAttachment] = []
    /// True while ANY `AgentRuntime` run is in flight for this bot — its own
    /// chat, a delegation reply, or a group-chat turn — not just the chat
    /// queue. Kept true continuously from `acquireRunLock()` to
    /// `releaseRunLock()` so those three never drive the same sandbox
    /// concurrently, and so `pendingApproval` (a single slot, not a queue)
    /// is never written by two runs at once.
    var isBusy = false
    /// Tagged with an id so a specific waiter can be found and removed
    /// out of FIFO order — see `cancelRunLockWaiter`. The continuation's
    /// `Bool` distinguishes a real hand-off (`true`, from `releaseRunLock`)
    /// from being resumed early because the waiting `Task` was cancelled
    /// (`false`, from `cancelRunLockWaiter`) — `acquireRunLock` throws on
    /// the latter instead of returning normally, which matters: if it
    /// returned normally here, the caller's `defer { releaseRunLock() }`
    /// would fire for a lock this waiter never actually held, releasing
    /// a slot that still rightfully belongs to whoever's really running
    /// and letting a third run start concurrently with them.
    private struct RunLockWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var runLockWaiters: [RunLockWaiter] = []
    /// Set the moment a run actually acquires the lock (not while still
    /// queued), cleared when it releases — see `RunLockOwner`'s doc
    /// comment for why this exists: it's what lets `stop()` tell whether
    /// a currently-pending approval is actually this bot's own chat's to
    /// resolve, or belongs to an unrelated delegation/group turn that
    /// merely happens to be occupying the same shared `pendingApproval`
    /// slot right now.
    private var currentRunLockOwner: RunLockOwner?
    /// Reentrancy guard for the chat-queue drain loop specifically —
    /// separate from `isBusy`, since a message can arrive (and needs a
    /// drain loop started) while `isBusy` is already true because of an
    /// unrelated delegation/group turn holding the run lock.
    private var isDrainingQueue = false
    /// The `Task` currently running `drainQueue` for this bot's own 1:1
    /// chat — cancelled by `stop()`. Not for delegation/group turns (those
    /// aren't user-visible "a message is processing" in the same chat, and
    /// stopping one from here would be surprising).
    private var drainTask: Task<Void, Never>?
    /// What the live `runtime` was built with — see `currentRuntimeSettingsKey`.
    private var runtimeSettingsKey: String?
    /// Results this bot's runs have already seen (15 minutes): a re-woken run that only re-checks is caught fast.
    let seenResults = SeenResults()
    /// The 1:1 chat's current run, reviewed for a lesson when it ends (see `reviewRunForLesson`).
    private var ownChatLessonTrail = LessonTrail()
    private var lastLessonReview = Date.distantPast
    /// Everything baked into an `AgentRuntime` at creation that the user can
    /// change in Settings: provider, model, vision, endpoint, budgets, and
    /// whether a new API key is pending.
    private var currentRuntimeSettingsKey: String {
        [
            modelProvider.rawValue, selectedModel, String(modelHasVision), remoteBaseURLText,
            maxTokensText, maxIterationsText, String(remoteAPIKeyInput.hashValue), engine.rawValue,
            String(systemPromptText.hashValue), selectedSkillIDs.sorted().joined(separator: ","),
            fallbackProvider?.rawValue ?? "", fallbackModel, fallbackBaseURLText, String(fallbackHasVision), String(fallbackAPIKeyInput.hashValue),
        ].joined(separator: "|")
    }
    /// Whether THIS chat specifically (not a delegation/group turn — see
    /// `isBusy`'s broader scope) has a message in flight right now — what
    /// the "Stop" button in `BotDetailView` actually gates on.
    var isProcessingMessage: Bool { drainTask != nil }
    /// One user turn waiting for the runtime — text plus any images that
    /// came from `pendingAttachments`. Staged here (rather than sent
    /// immediately) while the agent is still working through an earlier
    /// one, and drained in order by `drainQueue`.
    struct QueuedMessage {
        var text: String
        var images: [String] = []
    }
    var messageQueue: [QueuedMessage] = []
    var hasStarted = false
    var pendingApproval: PendingApproval?
    var pendingCredentialRequest: PendingCredentialRequest?
    /// Durable changes (memories, routines) the agent tried to make after
    /// reading untrusted content, held until the user approves them — see
    /// `GuardrailPolicy` / `PendingInboxStore`.
    var pendingReview: [PendingItem] = []
    /// Which engine runs this bot's own-chat turns. Group turns, delegations
    /// and routines always use the built-in engine.
    var engine: AgentEngineKind = .builtin
    /// Set whenever an assistant/tool message arrives (see `handleEvent`),
    /// cleared by `markRead()` — which `BotDetailView` calls whenever this
    /// bot is the one actually on screen. Session-scoped, not persisted:
    /// unlike the transcript itself, "have I looked at this yet" isn't
    /// meaningful to carry across a relaunch the way the messages are.
    var hasUnread = false
    /// Index into `displayMessages` of the assistant bubble currently being
    /// filled in by `.messageDelta` events, or `nil` between turns. See
    /// `handleEvent`.
    private var streamingIndex: Int?
    /// Armed on `.status(.executing)` when `streamingIndex` is about to
    /// be reused across a no-tool-call retry — see `handleEvent`.
    private var pendingReuseClear = false

    var sandbox: RemoteSandboxManager?
    var handle: SandboxHandle?
    var runtime: (any AgentEngine)?

    /// Populated from `OllamaBackend.availableModels()` once `ollama serve`
    /// answers. Locked in the moment the first message starts the agent —
    /// each `AgentRuntime` is one model for its whole life; running several
    /// bots on different models means running several bots, not switching
    /// one mid-conversation.
    var availableModels: [String] = []
    var selectedModel = "qwen2.5:7b-instruct"
    /// Overrides `OllamaBackend`'s name-based vision-capability guess — model
    /// names don't follow a fixed convention, so this is the reliable path
    /// rather than trying to keep widening a substring list.
    var modelHasVision = true
    /// `.ollama` talks to the local `ollama serve` process `boot()` already
    /// waits for; `.remote` talks to `remoteBaseURLText`, any OpenAI-
    /// `/v1/chat/completions`-compatible server. See `makeModelBackend()`.
    var modelProvider: ModelProvider = .ollama
    /// Only meaningful when `modelProvider == .remote` — e.g.
    /// "https://api.openai.com/v1" or a self-hosted vLLM/LM Studio URL,
    /// including whatever path prefix that server expects before
    /// `/chat/completions` and `/models`.
    var remoteBaseURLText = ""
    /// UI-only scratch space for `BotSettingsTab`'s API key field — never
    /// persisted here (see `BotConfig`'s doc comment) and never prefilled
    /// with a saved key's actual value. Written to `SecretStore` and
    /// cleared back to "" by `persistRemoteAPIKeyIfChanged()` when the
    /// settings sheet closes.
    var remoteAPIKeyInput = ""
    /// A second model for when the main one can't be reached after a few tries (`FallbackBackend`). `nil`: none.
    var fallbackProvider: ModelProvider?
    var fallbackModel = ""
    var fallbackBaseURLText = ""
    var fallbackHasVision = false
    /// UI scratch for the fallback's API key, same as `remoteAPIKeyInput`.
    var fallbackAPIKeyInput = ""
    /// Whether requests are on the fallback right now, kept across this bot's runs.
    let fallbackState = FallbackState()
    /// ONLY what the user (or `create_bot`) added — the built-in prompt
    /// (`BuiltInSystemPrompt.text`) is always applied separately and is not
    /// editable. See `fullSystemPrompt`.
    var systemPromptText = ""
    /// Why the last `respondInGroup` returned nil because of a failure (nil when it was a genuine silence).
    var lastTurnFailure: String?
    /// What the last isolated run's tools ran and returned (bounded), and how many real tool calls it made.
    var lastTurnObservations = ""
    /// The own-chat run's recent tool results (bounded), so a stop update can say what was actually seen.
    var lastOwnChatToolOutput = ""
    var lastTurnToolCalls = 0
    /// Last assistant text logged per debug context, to flag a model repeating itself.
    private var lastLoggedAssistantText: [String: String] = [:]

    /// Loaded once from the bundled `skills/` folder (see `SkillLibrary`).
    /// Defaults to everything selected — the index alone is cheap (see
    /// `ToolRegistry`'s lazy `use_skill` loading), so there's little cost to
    /// starting with the full set available.
    var availableSkills: [Skill] = SkillLibrary.loadAll()
    var selectedSkillIDs: Set<String> = Set(SkillLibrary.loadAll().map(\.id))

    /// Exposed rather than hardcoded: the system prompt (which can include
    /// a skills index) gets resent in full on every loop iteration — that's
    /// just how the chat API works — so a big skill selection burns through
    /// the default budget in a handful of turns. Let the user raise it
    /// instead of hitting a silent wall.
    var maxTokensText = "200000"
    var maxIterationsText = "40"

    /// Durable instructions/preferences about this bot, carried into every
    /// future conversation's system prompt (see `fullSystemPrompt`) — added
    /// either by the model itself (the `remember` tool, wired below in
    /// `drainQueue`) or by hand in the settings sheet's Memory section.
    /// Persisted separately from `BotConfig` — see `BotMemoryStore`.
    var memories: [String] = []
    /// The managed long-term notes behind `memories` (same order): importance, recency, usage, pinning.
    var memoryBook = MemoryBook()
    private var lastConsolidation = Date.distantPast
    private var embeddingInFlight = false
    private var embeddingRerunRequested = false
    private var embeddingChangeObserver: NSObjectProtocol?
    private var embeddingBackoffUntil = Date.distantPast
    /// How many notes have a meaning vector, for the settings screen.
    var memoriesIndexed: Int { memoryBook.embeddedCount }

    /// One-shot tasks this bot has been assigned and is carrying —
    /// unlike `memories` (durable, kept forever) these are meant to be
    /// removed once done (`complete_task`), and unlike a `Routine`
    /// they're not scheduled, just "currently in progress." Included in
    /// `fullSystemPrompt` the same way memories/routines are, so a task
    /// assigned in this bot's own 1:1 chat is still visible if it's
    /// later @mentioned in a group or asked about via delegation —
    /// neither of those has access to this chat's actual history.
    /// Persisted separately — see `BotTaskStore`.
    var tasks: [BotTask] = []

    /// Time-based triggers that queue a message to this bot on their own
    /// (see `Routine`) — created by hand in the settings sheet's Routines
    /// section, or by the model via `create_routine`. Only fire while this
    /// app is running: there's no background daemon behind this, just
    /// in-process `Timer`s (`routineTimers`) rescheduled on launch from
    /// each routine's own `nextFireDate`.
    var routines: [Routine] = []
    private var routineTimers: [String: Timer] = [:]

    /// The most recent digest `AgentRuntime.compact` produced for this
    /// bot's own chat (never set from a delegation/group turn's
    /// isolated, no-history runtime — see `handleEvent`'s
    /// `.contextCompacted` case) — read back in `drainQueue` so seeding
    /// a FRESH `AgentRuntime` (a relaunch, or whenever `runtime` is
    /// `nil`) can resend just [this summary + whatever's newer than it]
    /// instead of the bot's entire persisted history, which would
    /// immediately get re-summarized right back down to roughly this
    /// same thing anyway — see `ContextSummaryStore`'s doc comment for
    /// why that repeated round trip was worth caching against.
    private var contextSummary: ContextSummary?

    /// Mirrors `permissions`' lists for display — refreshed after every
    /// change rather than read live, since the store is an actor and
    /// SwiftUI needs a plain synchronous value here.
    var sessionAllowedBinaries: [String] = []
    var globalAllowedBinaries: [String] = []
    var blanketShellScopes: [RunShellPermissions.BlanketScope] = []

    private let permissions: RunShellPermissions
    /// Shared across every bot — how this one finds and messages its
    /// siblings. See `BotDirectory`, `delegateToBot`.
    let botDirectory: BotDirectory

    init(
        id: String, name: String, colorHex: String, tagline: String = "", group: String = "General",
        permissions: RunShellPermissions, botDirectory: BotDirectory
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.tagline = tagline
        self.group = group
        self.permissions = permissions
        self.botDirectory = botDirectory
        loadPersistedTranscriptAndMemory()
    }

    /// Reconstructs a bot from a saved `BotConfig` — same as the plain
    /// `init`, plus every other field `BotStore` persists. Used by
    /// `ContentView` on launch instead of `init` when there's a saved
    /// sidebar to restore.
    convenience init(config: BotConfig, permissions: RunShellPermissions, botDirectory: BotDirectory) {
        self.init(
            id: config.id, name: config.name, colorHex: config.colorHex,
            tagline: config.tagline, group: config.group, permissions: permissions, botDirectory: botDirectory
        )
        avatarStyle = config.avatarStyle
        systemPromptText = BuiltInSystemPrompt.userPortion(of: config.systemPromptText)
        selectedSkillIDs = SkillLibrary.reconcileSelection(
            saved: config.selectedSkillIDs, known: config.knownSkillIDs, available: Set(availableSkills.map(\.id))
        )
        selectedModel = config.selectedModel
        modelHasVision = config.modelHasVision
        maxTokensText = config.maxTokensText
        maxIterationsText = config.maxIterationsText
        modelProvider = config.modelProvider ?? .ollama
        engine = config.engine ?? .builtin
        remoteBaseURLText = config.remoteBaseURLText ?? ""
        checksGoalWorkItself = config.checksGoalWorkItself ?? true
        fallbackProvider = config.fallbackProvider
        fallbackModel = config.fallbackModel ?? ""
        fallbackBaseURLText = config.fallbackBaseURLText ?? ""
        fallbackHasVision = config.fallbackHasVision ?? false
    }

    /// Takes every setting from `config` except the id (a settings import). The conversation, memory and
    /// sandbox stay; a 1:1 chat picks the new settings up on its next message.
    func apply(_ config: BotConfig) {
        name = config.name
        colorHex = config.colorHex
        avatarStyle = config.avatarStyle
        tagline = config.tagline
        group = config.group
        systemPromptText = BuiltInSystemPrompt.userPortion(of: config.systemPromptText)
        selectedSkillIDs = SkillLibrary.reconcileSelection(
            saved: config.selectedSkillIDs, known: config.knownSkillIDs, available: Set(availableSkills.map(\.id))
        )
        selectedModel = config.selectedModel
        modelHasVision = config.modelHasVision
        maxTokensText = config.maxTokensText
        maxIterationsText = config.maxIterationsText
        modelProvider = config.modelProvider ?? .ollama
        engine = config.engine ?? .builtin
        remoteBaseURLText = config.remoteBaseURLText ?? ""
        checksGoalWorkItself = config.checksGoalWorkItself ?? true
        fallbackProvider = config.fallbackProvider
        fallbackModel = config.fallbackModel ?? ""
        fallbackBaseURLText = config.fallbackBaseURLText ?? ""
        fallbackHasVision = config.fallbackHasVision ?? false
    }

    /// Reconstructs a bot from an imported/duplicated `BotTemplate` — same
    /// settings fields as `init(config:)`, plus the memory and routines a
    /// template carries. Always takes a caller-supplied `id` (never the
    /// source bot's own), so it boots its own fresh sandbox rather than
    /// reattaching to someone else's persistent container. Only sets this
    /// bot's own in-memory state — writing the memory/routines to disk
    /// under `id` is the caller's job (see `ContentView.commitDraftBot`),
    /// same as `config`'s settings aren't written until `saveBots()` runs.
    convenience init(id: String, template: BotTemplate, permissions: RunShellPermissions, botDirectory: BotDirectory) {
        self.init(
            id: id, name: template.name, colorHex: template.colorHex,
            tagline: template.tagline, group: template.group, permissions: permissions, botDirectory: botDirectory
        )
        avatarStyle = template.avatarStyle
        systemPromptText = BuiltInSystemPrompt.userPortion(of: template.systemPromptText)
        selectedSkillIDs = SkillLibrary.reconcileSelection(
            saved: template.selectedSkillIDs, known: nil, available: Set(availableSkills.map(\.id))
        )
        selectedModel = template.selectedModel
        modelHasVision = template.modelHasVision
        maxTokensText = template.maxTokensText
        maxIterationsText = template.maxIterationsText
        modelProvider = template.modelProvider ?? .ollama
        remoteBaseURLText = template.remoteBaseURLText ?? ""
        checksGoalWorkItself = template.checksGoalWorkItself ?? true
        fallbackProvider = template.fallbackProvider
        fallbackModel = template.fallbackModel ?? ""
        fallbackBaseURLText = template.fallbackBaseURLText ?? ""
        fallbackHasVision = template.fallbackHasVision ?? false
        memoryBook = MemoryBook(legacy: template.memories)
        memories = memoryBook.texts
        routines = template.routines
        // Deliberately NOT scheduled here: this bot is only a draft until
        // the user commits it (a cancelled import/duplicate would otherwise
        // leave live timers firing into a bot that never existed).
        // `activateRoutines()` runs from `commitDraftBot`.
    }

    /// Starts timers for routines that arrived via a template — called once
    /// the draft is actually added.
    func activateRoutines() {
        for routine in routines { scheduleTimer(for: routine) }
    }

    /// This bot's settings, memory, and routines — everything a template
    /// needs to recreate an equivalent bot elsewhere (export, or
    /// "Duplicate…"). Deliberately excludes `id`, the conversation
    /// transcript, and anything sandbox-identity-related — see
    /// `BotTemplate`'s doc comment.
    var asTemplate: BotTemplate {
        BotTemplate(
            name: name, colorHex: colorHex, avatarStyle: avatarStyle, tagline: tagline, group: group,
            systemPromptText: systemPromptText, selectedSkillIDs: selectedSkillIDs, selectedModel: selectedModel,
            modelHasVision: modelHasVision, maxTokensText: maxTokensText, maxIterationsText: maxIterationsText,
            memories: memories, routines: routines, modelProvider: modelProvider, remoteBaseURLText: remoteBaseURLText,
            checksGoalWorkItself: checksGoalWorkItself, fallbackProvider: fallbackProvider, fallbackModel: fallbackModel,
            fallbackBaseURLText: fallbackBaseURLText, fallbackHasVision: fallbackHasVision
        )
    }

    /// Everything about this bot `BotStore` writes to `bots.json` — identity
    /// plus the settings surfaced in `BotSettingsTab`. Deliberately NOT the
    /// transcript (`TranscriptStore`) or the remembered-instructions list
    /// (`BotMemoryStore`) — see those types' doc comments for why each gets
    /// its own file instead of living here — and NOT the live sandbox/model
    /// connection, which isn't persistable at all: restarting reattaches to
    /// the same persistent sandbox container, and `drainQueue` reseeds a
    /// fresh `AgentRuntime` with the restored transcript rather than trying
    /// to resume the actual live model session.
    var config: BotConfig {
        BotConfig(
            id: id, name: name, colorHex: colorHex, avatarStyle: avatarStyle, tagline: tagline, group: group,
            systemPromptText: systemPromptText, selectedSkillIDs: selectedSkillIDs, selectedModel: selectedModel,
            modelHasVision: modelHasVision, maxTokensText: maxTokensText, maxIterationsText: maxIterationsText,
            modelProvider: modelProvider, remoteBaseURLText: remoteBaseURLText,
            engine: engine, knownSkillIDs: Set(availableSkills.map(\.id)), checksGoalWorkItself: checksGoalWorkItself,
            fallbackProvider: fallbackProvider, fallbackModel: fallbackModel, fallbackBaseURLText: fallbackBaseURLText,
            fallbackHasVision: fallbackHasVision
        )
    }

    /// Keychain name for this bot's remote provider API key — derived from
    /// `id` rather than stored anywhere, so there's no separate field to
    /// keep in sync (see `BotConfig`'s doc comment for why the key itself
    /// never appears there). `SecretStore` names must be uppercase
    /// letters/digits/underscore starting with a letter; `id` is
    /// lowercase-and-hyphens ("bot-xxxxxxxx"), hence the transform.
    var remoteAPIKeySecretName: String {
        "REMOTE_API_KEY_" + id.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    /// Writes `remoteAPIKeyInput` to the Keychain if the user actually
    /// typed something, then clears the field — called when a settings
    /// sheet closes (create or edit), same "only touches disk on
    /// dismiss" timing as `saveBots()`. A blank field means "leave
    /// whatever's already saved alone," not "clear it."
    func persistRemoteAPIKeyIfChanged() async {
        guard !remoteAPIKeyInput.isEmpty else { return }
        try? await SecretStore().put(
            name: remoteAPIKeySecretName, value: remoteAPIKeyInput,
            notes: "Remote model provider API key for bot '\(name)'"
        )
        remoteAPIKeyInput = ""
        if !fallbackAPIKeyInput.isEmpty {
            try? await SecretStore().put(
                name: fallbackAPIKeySecretName, value: fallbackAPIKeyInput,
                notes: "Fallback model provider API key for bot '\(name)'"
            )
            fallbackAPIKeyInput = ""
        }
    }

    /// Keychain name for the fallback model's API key (covered by the app-internal `REMOTE_API_KEY_` prefix).
    var fallbackAPIKeySecretName: String { remoteAPIKeySecretName + "_FALLBACK" }

    /// The actual `ModelBackend` this bot's runtime talks to — local
    /// Ollama, or the configured remote OpenAI-compatible endpoint. The
    /// remote branch's API key never touches the agent loop or a log; it
    /// goes straight from `SecretStore.resolveOne` into this request's
    /// own `Authorization` header.
    /// `interactive`: the user is waiting on this run in the 1:1 chat. Local-model requests go through the
    /// shared `ModelScheduler`, so the bots with the most to do get the model first.
    private func makeModelBackend(interactive: Bool = false) async -> any ModelBackend {
        let primary = await makeBackend(provider: modelProvider, model: selectedModel, baseURL: remoteBaseURLText,
                                        keyName: remoteAPIKeySecretName, vision: modelHasVision, interactive: interactive)
        let fallbackName = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fallbackProvider, !fallbackName.isEmpty else { return primary }
        let fallback = await makeBackend(provider: fallbackProvider, model: fallbackName, baseURL: fallbackBaseURLText,
                                         keyName: fallbackAPIKeySecretName, vision: fallbackHasVision, interactive: interactive)
        let mainName = selectedModel
        return FallbackBackend(primary: primary, fallback: fallback, fallbackModel: fallbackName, state: fallbackState) { [weak self] toFallback, reason in
            Task { @MainActor in self?.noteModelSwitch(toFallback: toFallback, reason: reason, main: mainName, fallback: fallbackName) }
        }
    }

    private func makeBackend(provider: ModelProvider, model: String, baseURL: String, keyName: String, vision: Bool,
                             interactive: Bool) async -> any ModelBackend {
        switch provider {
        case .ollama:
            let local = OllamaBackend(defaultModel: model, visionOverrides: vision ? [model] : [])
            return ScheduledBackend(local, bot: name) { [weak self] in
                await MainActor.run { self?.modelPriority(interactive: interactive) ?? 0 }
            }
        case .remote:
            // A key typed in Settings is used right away; the Keychain gets it when the sheet closes.
            let typed = keyName == fallbackAPIKeySecretName ? fallbackAPIKeyInput : (keyName == remoteAPIKeySecretName ? remoteAPIKeyInput : "")
            let apiKey = typed.isEmpty ? ((try? await SecretStore().resolveOne(name: keyName)) ?? nil) : typed
            let url = URL(string: baseURL) ?? URL(string: "https://api.openai.com/v1")!
            // An Ollama server on another machine: use its native API, which applies the context window setting.
            if (apiKey ?? "").isEmpty, let root = ModelTiers.ollamaRoot(url) {
                return OllamaBackend(baseURL: root, defaultModel: model, visionOverrides: vision ? [model] : [])
            }
            return OpenAICompatibleBackend(baseURL: url, apiKey: apiKey ?? "", defaultModel: model, visionOverrides: vision ? [model] : [])
        }
    }

    /// One line in the bot's chat (and the debug console) each time requests move between its models.
    private func noteModelSwitch(toFallback: Bool, reason: String, main: String, fallback: String) {
        let text = toFallback
            ? "Couldn't reach my main model (\(main): \(reason)), so I'm using my fallback model (\(fallback)) for now. I'll try the main one again in a few minutes."
            : "My main model (\(main)) is answering again, so I'm back on it."
        displayMessages.append(DisplayMessage(role: .assistant, text: "(Model) " + text))
        persistTranscript()
        if DebugSettings.shared.isEnabled {
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "model", text: text)
        }
    }

    /// A number typed into a settings field: spaces and thousands separators ("100 ", "200,000") are fine;
    /// anything unreadable falls back to the default, and the value is kept within `range`.
    static func parsedLimit(_ text: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        if isUnlimited(text) { return Int.max }
        let digits = text.filter { !$0.isWhitespace && $0 != "," && $0 != "_" }
        guard let value = Int(digits) else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// "unlimited" (or ∞) in a limit field: no cap. Only offered for tokens; the iteration and time limits and the
    /// loop guards still end a runaway run.
    static func isUnlimited(_ text: String) -> Bool {
        ["unlimited", "∞", "none", "no limit"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// How much this bot needs the model right now, for `ModelScheduler` (which adds recent use and waiting time).
    /// The user waiting on a reply comes first, then goal work ready to do, goal reviews owed, and open tasks.
    func modelPriority(interactive: Bool) -> Double {
        var score = interactive ? 100.0 : 0
        for group in botDirectory.allGroups() where group.members.contains(where: { $0.id == id }) {
            guard let goal = group.goal, goal.isLive, goal.status == .active else { continue }
            score += Double(min(goal.actionableStepCount(for: name), 3)) * 12
            if goal.ownerBotID == id, goal.ownerReviewWork() != nil { score += 15 }
        }
        score += Double(min(tasks.count, 5)) * 3
        return score
    }

    private func loadPersistedTranscriptAndMemory() {
        let entries = TranscriptStore.load(id: id)
        if !entries.isEmpty {
            displayMessages = entries.map {
                DisplayMessage(
                    role: $0.role, text: $0.text, attachmentNames: $0.attachmentNames ?? [],
                    interBotPeerID: $0.interBotPeerID, interBotPeerName: $0.interBotPeerName,
                    timestamp: $0.timestamp ?? Date(), toolName: $0.toolName, isTaskSummary: $0.isTaskSummary ?? false,
                    imageIDs: $0.imageIDs ?? []
                )
            }
            // Saved before summaries were judged per turn: show any whose answer was never shown otherwise.
            var shownThisTurn: [String] = []
            for index in displayMessages.indices {
                let message = displayMessages[index]
                if message.role == .user { shownThisTurn = []; continue }
                guard message.role == .assistant, message.toolName == nil, message.interBotPeerID == nil else { continue }
                if message.isTaskSummary {
                    displayMessages[index].isTaskSummary = SummaryDisplay.collapses(summary: message.text, shownThisTurn: shownThisTurn)
                } else {
                    shownThisTurn.append(message.text)
                }
            }
            hasStarted = true
        }
        // Reads the managed memory book (or migrates the old plain list), then tidies it once.
        memoryBook = BotMemoryStore.loadBook(id: id)
        memories = memoryBook.texts
        consolidateMemories(force: false)
        Task { @MainActor [weak self] in await self?.embedPendingMemories() }
        // A different embedding model (or a switch between local and remote): re-index every note for it.
        embeddingChangeObserver = NotificationCenter.default.addObserver(forName: ModelTiers.embeddingChangedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.embeddingModelChanged() }
        }
        routines = RoutineStore.load(id: id)
        for routine in routines { scheduleTimer(for: routine) }
        contextSummary = ContextSummaryStore.load(id: id)
        tasks = BotTaskStore.load(id: id)
    }

    private var transcriptSaveTask: Task<Void, Never>?

    /// Debounced (~400ms trailing) with JSON encoding and the disk write
    /// off the main actor — it used to re-encode and rewrite the whole
    /// transcript synchronously on every message, O(n) on the UI thread.
    /// Only the cheap struct mapping stays on the main actor.
    private func persistTranscript() {
        transcriptSaveTask?.cancel()
        let botID = id
        transcriptSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            let entries = self.displayMessages.map {
                TranscriptEntry(
                    role: $0.role, text: $0.text, attachmentNames: $0.attachmentNames.isEmpty ? nil : $0.attachmentNames,
                    interBotPeerID: $0.interBotPeerID, interBotPeerName: $0.interBotPeerName, timestamp: $0.timestamp,
                    toolName: $0.toolName, isTaskSummary: $0.isTaskSummary, imageIDs: $0.imageIDs.isEmpty ? nil : $0.imageIDs
                )
            }
            TranscriptStore.saveInBackground(id: botID, entries)
        }
    }

    /// Wipes this bot's conversation — the settings sheet's "Delete
    /// conversation" — without touching its settings, memory, or routines.
    /// `runtime` is just dropped, not asked to do anything: the next
    /// message lazily builds a fresh one (see `drainQueue`), the same path
    /// a brand-new bot's first message already takes.
    /// Debug mode only, and only while this bot isn't doing anything: editing history under a running turn
    /// would change what it's working from mid-step.
    var canEditMessages: Bool {
        DebugSettings.shared.isEnabled && !isBusy && messageQueue.isEmpty && pendingApproval == nil && pendingCredentialRequest == nil
    }

    func editMessage(id messageID: UUID, text: String) {
        guard canEditMessages, let index = displayMessages.firstIndex(where: { $0.id == messageID }) else { return }
        displayMessages[index].text = text
        forgetModelContextAfterEdit()
    }

    func deleteMessage(id messageID: UUID) {
        guard canEditMessages, let index = displayMessages.firstIndex(where: { $0.id == messageID }) else { return }
        displayMessages.remove(at: index)
        streamingIndex = nil
        forgetModelContextAfterEdit()
    }

    /// The model's copy of the conversation (and its saved summary) predates the edit: drop both, so the next
    /// message rebuilds the context from the edited transcript (see `drainQueue`).
    private func forgetModelContextAfterEdit() {
        runtime = nil
        contextSummary = nil
        ContextSummaryStore.delete(id: id)
        persistTranscript()
        if DebugSettings.shared.isEnabled {
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "debug", text: "transcript edited — the model's context will be rebuilt on the next message")
        }
    }

    func clearConversation() {
        displayMessages = []
        messageQueue = []
        streamingIndex = nil
        hasStarted = false
        runtime = nil
        // The compacted summary of the OLD conversation would otherwise seed
        // the next one, so "delete" wouldn't really delete what the model sees.
        contextSummary = nil
        ContextSummaryStore.delete(id: id)
        cancelPendingTranscriptSave()
        TranscriptStore.delete(id: id)
    }

    /// App quit: write the transcript right now instead of waiting out the
    /// debounce (which would drop the last ~400 ms of messages).
    func flushTranscriptNow() {
        guard transcriptSaveTask != nil else { return }
        transcriptSaveTask?.cancel()
        transcriptSaveTask = nil
        TranscriptStore.saveNow(id: id, displayMessages.map {
            TranscriptEntry(
                role: $0.role, text: $0.text, attachmentNames: $0.attachmentNames.isEmpty ? nil : $0.attachmentNames,
                interBotPeerID: $0.interBotPeerID, interBotPeerName: $0.interBotPeerName, timestamp: $0.timestamp,
                toolName: $0.toolName, isTaskSummary: $0.isTaskSummary, imageIDs: $0.imageIDs.isEmpty ? nil : $0.imageIDs
            )
        })
    }

    /// Stops a debounced save from resurrecting a transcript file that's
    /// about to be (or just was) deleted.
    func cancelPendingTranscriptSave() {
        transcriptSaveTask?.cancel()
        transcriptSaveTask = nil
    }

    /// The settings sheet's "Delete bot" — unlike every other teardown path
    /// in this app (`removeBot`, closing the app, …), which deliberately
    /// leave a persistent sandbox running so re-adding the same id
    /// reattaches to it, this one actually tears the container down. Best
    /// effort: if the sandbox is already unreachable, there's nothing left
    /// to destroy, so a failure here shouldn't block deleting the bot
    /// itself.
    /// Wipes this bot's Linux sandbox and boots a fresh one from the image —
    /// the recovery path if the container is (or might be) compromised.
    /// Everything inside the old container is destroyed (installed tools,
    /// `/home/box`, browser profile, running processes). `/workspace` lives
    /// on a Docker volume and survives unless `wipeWorkspace` is set.
    /// Also stops the current run and drops the runtime, so the next
    /// message starts against the new container (chat history is kept).
    func resetSandbox(wipeWorkspace: Bool) async {
        guard let sandbox, let oldHandle = handle else { return }
        // The legacy compose-managed computer is shared and unowned; the
        // manager refuses to destroy it, so a "reset" would silently no-op.
        guard oldHandle.id != "agent-sandbox" else {
            status = "This is the shared legacy sandbox and can't be reset from the app."
            return
        }
        stop()
        runtime = nil
        state = .booting(id)
        status = "Resetting sandbox…"
        do {
            try await sandbox.forceDestroy(oldHandle.id)
            let created = try await sandbox.create(taskID: id, persistent: true)
            handle = created
            Task { await self.configureVMBasics(sandbox: sandbox, sandboxID: created.id) }
            if let vncString = created.metadata["vnc_url"], let vncURL = URL(string: vncString) {
                state = .running(vncURL: vncURL)
            } else {
                state = .failed("Sandbox reset but returned no vnc_url")
            }
            var wiped = !wipeWorkspace
            if wipeWorkspace {
                let result = try? await sandbox.exec(created.id, command: "find /workspace/ -mindepth 1 -delete", timeout: 60, env: nil)
                wiped = result?.succeeded == true
            }
            status = !wipeWorkspace ? "Sandbox reset (workspace files kept)."
                : (wiped ? "Sandbox reset and workspace wiped." : "Sandbox reset, but wiping /workspace FAILED — its files are still there.")
            if DebugSettings.shared.isEnabled {
                DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "sandbox",
                                    text: "sandbox reset (\(wipeWorkspace ? "workspace wiped" : "workspace kept"))")
            }
        } catch {
            state = .failed(error.localizedDescription)
            status = "Sandbox reset failed: \(error.localizedDescription)"
        }
    }

    /// Every VM gets a git identity (the bot's name) and gh as GitHub's credential helper, so commits don't fail
    /// with "Author identity unknown" and git commands run with use_secrets: ["GITHUB_TOKEN"] just work. Only
    /// fills in what's missing; a bot's own later settings win.
    func configureVMBasics(sandbox: RemoteSandboxManager, sandboxID: String) async {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let command = """
            git config --global user.name >/dev/null || git config --global user.name \(shellQuote(name)); \
            git config --global user.email >/dev/null || git config --global user.email \(shellQuote((slug.isEmpty ? "bot" : slug) + "@shellhouse.local")); \
            if command -v gh >/dev/null && ! git config --global --get-all credential.https://github.com.helper | grep -q 'gh auth git-credential'; then \
              git config --global credential.https://github.com.helper '' && \
              git config --global --add credential.https://github.com.helper '!/usr/bin/gh auth git-credential'; fi
            """
        // The container reports "created" a moment before it accepts commands: retry for up to ~40 s.
        for attempt in 0..<8 {
            if let result = try? await sandbox.exec(sandboxID, command: command, timeout: 20, env: nil), result.exitCode == 0 { return }
            try? await Task.sleep(nanoseconds: UInt64(2 + attempt) * 1_000_000_000)
        }
        if DebugSettings.shared.isEnabled {
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .error, context: "sandbox", text: "couldn't set the VM's git identity and GitHub credential helper")
        }
    }

    func destroySandbox() async {
        guard let sandbox, let handle else { return }
        try? await sandbox.forceDestroy(handle.id)
    }

    /// Adds one remembered instruction and saves it immediately — called
    /// both from the settings sheet's Memory section and from the
    /// `remember` tool (via `drainQueue`'s `onRemember` closure), so either
    /// path needs exactly one place that actually writes `BotMemoryStore`.
    /// Skips an exact (case-insensitive) duplicate rather than appending it
    /// again — the model calling `remember` twice for the same fact in one
    /// conversation (it has no visibility into whether it already has,
    /// since the memory list is only reloaded into its prompt at the start
    /// of a conversation, not live) shouldn't leave two identical entries.
    /// Returns whether this is actually durable now — `true` for an
    /// already-remembered exact duplicate (nothing new to save, but
    /// nothing wrong either) or a successful fresh write; `false` only
    /// when `BotMemoryStore.save` itself failed, so the `remember` tool
    /// can say so instead of unconditionally reporting `"saved": true`
    /// the way it used to (see that tool's wiring in `ToolRegistry`).
    /// Capped, unlike the conversation history (`AgentRuntime.compact`)
    /// — `fullSystemPrompt` resends every entry here verbatim on EVERY
    /// turn, for every run (a bot's own chat, every group turn, every
    /// delegation), with no compaction step of its own. That was a
    /// slow-growing list before; `delegateToBot`'s automatic
    /// remembering of every delegation's outcome makes it grow much
    /// faster, so this now actually matters rather than being
    /// theoretical. Oldest entries drop first — a FIFO cap, not an
    /// attempt to judge which memory matters more than another.
    @discardableResult
    func addMemory(_ text: String, source: String = "self", importance: Int? = nil, pinned: Bool = false) -> Bool {
        let previousBook = memoryBook
        let outcome = memoryBook.add(text, importance: importance, source: source, pinned: pinned)
        if outcome == .rejected { return false }
        let evicted = memoryBook.evictOverCapacity()
        // Persist before archiving: a failed save restores the book, and nothing is archived twice.
        guard BotMemoryStore.saveBook(id: id, memoryBook) else {
            memoryBook = previousBook
            return false
        }
        BotMemoryStore.archive(id: id, evicted)
        memories = memoryBook.texts
        consolidateMemories(force: false)
        Task { @MainActor [weak self] in await self?.embedPendingMemories() }
        return true
    }

    /// Merges near-duplicate notes and archives stale, low-value, never-used ones (see `MemoryBook.consolidate`).
    /// At most once a day unless forced. Returns what changed.
    @discardableResult
    func consolidateMemories(force: Bool) -> MemoryBook.Consolidation {
        guard force || Date().timeIntervalSince(lastConsolidation) > 86_400, memoryBook.entries.count >= (force ? 1 : 8) else { return .init() }
        lastConsolidation = Date()
        let previous = memoryBook
        let report = memoryBook.consolidate()
        guard !report.isEmpty else { return report }
        guard BotMemoryStore.saveBook(id: id, memoryBook) else { memoryBook = previous; return .init() }
        BotMemoryStore.archive(id: id, report.archived)
        memories = memoryBook.texts
        return report
    }

    func setMemoryPinned(_ index: Int, _ pinned: Bool) {
        guard memoryBook.entries.indices.contains(index) else { return }
        memoryBook.setPinned(memoryBook.entries[index].id, pinned)
        BotMemoryStore.saveBook(id: id, memoryBook)
    }

    func setMemoryImportance(_ index: Int, _ value: Int) {
        guard memoryBook.entries.indices.contains(index) else { return }
        memoryBook.setImportance(memoryBook.entries[index].id, value)
        BotMemoryStore.saveBook(id: id, memoryBook)
    }

    /// The notes surfaced to the model just now count as used: that keeps what is actually useful fresh and
    /// lets what never helps age out. Saved only when something changed.
    private func noteMemoriesUsed(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        memoryBook.markUsed(ids)
        BotMemoryStore.saveBook(id: id, memoryBook)
    }

    // MARK: semantic indexing

    /// Gives every note a meaning vector from the selected embedding model, in the background. Safe to call often:
    /// one pass at a time, a failure (Ollama busy or the model missing) pauses retries for five minutes, and the
    /// bot keeps working on keyword search meanwhile.
    /// The embedding model changed: forget any pause, and index again for the new model (after the current pass, if one is running).
    func embeddingModelChanged() {
        embeddingBackoffUntil = .distantPast
        if embeddingInFlight { embeddingRerunRequested = true; return }
        Task { @MainActor [weak self] in await self?.embedPendingMemories() }
    }

    func embedPendingMemories() async {
        guard !embeddingInFlight, Date() >= embeddingBackoffUntil, !memoryBook.entries.isEmpty,
              let model = await ModelTiers.resolveEmbeddingModel() else { return }
        embeddingInFlight = true
        defer {
            embeddingInFlight = false
            if embeddingRerunRequested {
                embeddingRerunRequested = false
                Task { @MainActor [weak self] in await self?.embedPendingMemories() }
            }
        }
        guard let embedder = await ModelTiers.embedder(for: model) else { return }
        while true {
            // The setting changed while indexing: stop, the re-run starts with the new model.
            if embeddingRerunRequested { return }
            let pending = Array(memoryBook.entriesNeedingEmbedding(model: model).prefix(16))
            guard !pending.isEmpty else { return }
            do {
                let vectors = try await embedder.embed(pending.map(\.text), isQuery: false)
                for (entry, vector) in zip(pending, vectors) {
                    memoryBook.setEmbedding(id: entry.id, forText: entry.text, vector: vector, model: model)
                }
                BotMemoryStore.saveBook(id: id, memoryBook)
            } catch {
                embeddingBackoffUntil = Date().addingTimeInterval(300)
                if DebugSettings.shared.isEnabled {
                    DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "memory", text: "embedding paused for 5 min: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    /// The vector for a search, or nil when nothing is indexed yet / the embedder is unavailable (keyword search then).
    private func memoryQueryVector(_ text: String) async -> (vector: [Float], model: String)? {
        guard memoryBook.embeddedCount > 0, Date() >= embeddingBackoffUntil, let model = await ModelTiers.resolveEmbeddingModel() else { return nil }
        guard let embedder = await ModelTiers.embedder(for: model, timeout: 3),
              let vector = try? await embedder.embed([String(text.suffix(1_500))], isQuery: true).first else { return nil }
        return (vector, model)
    }

    /// The `recall_memory` tool's read side: exact substring matches first, then notes ranked by meaning + keywords
    /// + recency + importance, best first. An empty query lists the whole book.
    func recallMemory(matching query: String) async -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return memories }
        var results: [MemoryEntry] = memoryBook.entries.filter { $0.text.lowercased().contains(needle) }
        let q = await memoryQueryVector(query)
        for scored in memoryBook.rank(query: query, queryEmbedding: q?.vector, queryModel: q?.model, limit: 12)
        where !results.contains(where: { $0.id == scored.entry.id }) {
            results.append(scored.entry)
        }
        let top = Array(results.prefix(12))
        noteMemoriesUsed(top.map(\.id))
        return top.map(\.text)
    }

    /// Notes relevant to an incoming message; `withRelevantMemoryContext` puts them in front of the model so it does
    /// not have to notice them in a long list.
    /// How many notes the system prompt already lists in full (see `fullSystemPrompt`).
    static let coreMemoryLimit = 12

    private func memoriesRelevant(to text: String, limit: Int = 5) async -> [String] {
        // Every note is already in the system prompt: ranking them again would only cost
        // an embedding call on the shared model server.
        guard memoryBook.entries.count > Self.coreMemoryLimit else { return [] }
        let q = await memoryQueryVector(text)
        let ranked = memoryBook.rank(query: String(text.suffix(3_000)), queryEmbedding: q?.vector, queryModel: q?.model, limit: limit)
        noteMemoriesUsed(ranked.map(\.entry.id))
        return ranked.map(\.entry.text)
    }

    /// Prepended to whatever's actually sent to the model — never to what's shown in the transcript. A no-op when
    /// nothing relevant is stored.
    private func withRelevantMemoryContext(_ text: String) async -> String {
        let matches = await memoriesRelevant(to: text)
        guard !matches.isEmpty else { return text }
        let context = "(From your own memory, possibly relevant here:\n"
            + matches.map { "- \($0)" }.joined(separator: "\n") + ")\n\n"
        return context + text
    }

    func removeMemory(at offsets: IndexSet) {
        let previous = memoryBook
        let ids = Set(offsets.compactMap { memoryBook.entries.indices.contains($0) ? memoryBook.entries[$0].id : nil })
        memoryBook.remove(ids: ids)
        // A failed write must not leave the Settings sheet showing something as gone that is still on disk.
        if BotMemoryStore.saveBook(id: id, memoryBook) {
            memories = memoryBook.texts
        } else {
            memoryBook = previous
        }
    }

    // MARK: - Tasks

    /// Capped because `fullSystemPrompt` resends every active task in full
    /// on every turn, every run. Tasks are meant to be short-lived
    /// (completed and removed), so a pile of 60 of them sitting around
    /// would mean something's not calling `complete_task` when it
    /// should, not a legitimately large backlog worth keeping.
    private static let maxTasks = 20

    /// The `remember_task` tool's write side (also called from the
    /// settings sheet's Tasks section) — proactive and unconditional,
    /// same as `addMemory`: the model isn't asked to confirm first,
    /// because the whole point is carrying a task across contexts
    /// (a group turn, a delegation) that have no other way to learn
    /// about it. Deduped case-insensitively so re-stating the same task
    /// doesn't pile up duplicates.
    @discardableResult
    func addTask(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !tasks.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return true }
        let previous = tasks
        tasks.append(BotTask(text: trimmed))
        if tasks.count > Self.maxTasks {
            tasks.removeFirst(tasks.count - Self.maxTasks)
        }
        let persisted = BotTaskStore.save(id: id, tasks)
        if !persisted {
            tasks = previous
        }
        return persisted
    }

    /// Keeps a goal-step task in sync: adds it, or updates its wording if the step moved on.
    @discardableResult
    func trackGoalTask(key: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let previous = tasks
        if let index = tasks.firstIndex(where: { $0.key == key }) {
            guard tasks[index].text != trimmed else { return true }
            tasks[index].text = trimmed
        } else {
            tasks.append(BotTask(text: trimmed, key: key))
            if tasks.count > Self.maxTasks { tasks.removeFirst(tasks.count - Self.maxTasks) }
        }
        guard BotTaskStore.save(id: id, tasks) else { tasks = previous; return false }
        return true
    }

    /// Removes goal-step tasks: one exact key, or everything for a goal (`prefix: "goal:<id>/"`).
    func clearGoalTasks(key: String? = nil, prefix: String? = nil) {
        let previous = tasks
        tasks.removeAll { task in
            guard let k = task.key else { return false }
            if let key { return k == key }
            if let prefix { return k.hasPrefix(prefix) }
            return false
        }
        if tasks != previous, !BotTaskStore.save(id: id, tasks) { tasks = previous }
    }

    /// The settings sheet's manual remove — unlike `completeTaskFromTool`,
    /// this doesn't require an exact id (a row index is all the UI has).
    func removeTask(at offsets: IndexSet) {
        let previous = tasks
        tasks.remove(atOffsets: offsets)
        if !BotTaskStore.save(id: id, tasks) {
            tasks = previous
        }
    }

    /// The `list_tasks` tool — this bot's own current one-shot tasks,
    /// read live (same reasoning as `listRoutinesForTool`: the snapshot
    /// baked into the system prompt at the start of a run goes stale
    /// the moment `remember_task`/`complete_task` runs mid-run).
    func listTasksForTool() -> [[String: Any]] {
        tasks.map { ["id": $0.id, "text": $0.text, "created_at": ISO8601DateFormatter().string(from: $0.createdAt)] }
    }

    /// The `remember_task` tool's entry point.
    func addTaskFromTool(_ arguments: [String: AnyCodable]) -> [String: Any] {
        guard let text = arguments["text"]?.asString, !text.isEmpty else {
            return ["error": "remember_task requires non-empty 'text'"]
        }
        guard addTask(text) else {
            return ["error": "failed to save to disk — this task wasn't actually remembered"]
        }
        return ["saved": true]
    }

    /// The `complete_task` tool's entry point — removes it outright
    /// rather than marking it done-but-kept: a one-shot task has
    /// nothing left to say once it's finished, unlike a routine (which
    /// keeps recurring) or a memory (which stays relevant indefinitely).
    func completeTaskFromTool(_ arguments: [String: AnyCodable]) -> [String: Any] {
        guard let taskID = arguments["id"]?.asString, !taskID.isEmpty else {
            return ["error": "complete_task requires 'id' — see list_tasks for exact ids"]
        }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return ["error": "no task with id '\(taskID)' — see list_tasks for current ids"]
        }
        let previous = tasks
        let removed = tasks.remove(at: index)
        guard BotTaskStore.save(id: id, tasks) else {
            tasks = previous
            return ["error": "failed to save to disk — '\(taskID)' wasn't actually completed"]
        }
        return ["completed": true, "id": removed.id, "text": removed.text]
    }

    /// Picks up skills added/removed since this bot was created or last
    /// refreshed — `availableSkills` is otherwise only ever set once, at
    /// `init`, so a bot that existed before a new skill was pasted in via
    /// Settings would never see it without this. A no-op once the
    /// conversation has actually started, same lock as everything else in
    /// `BotSettingsTab` that only makes sense to change before the first
    /// message (the model's already-sent system prompt can't retroactively
    /// gain a skill).
    func refreshAvailableSkills() {
        let updated = SkillLibrary.loadAll()
        let updatedIDs = Set(updated.map(\.id))
        // New skills default to selected (matching a fresh bot's own
        // default of "everything on"); removed ones just drop out.
        selectedSkillIDs.formUnion(updatedIDs.subtracting(Set(availableSkills.map(\.id))))
        selectedSkillIDs.formIntersection(updatedIDs)
        availableSkills = updated
    }

    // MARK: - Routines

    /// `persisted` reflects whether the write to disk actually succeeded
    /// (see `RoutineStore.save`'s doc comment) — the in-memory `routines`
    /// array is updated either way (the timer still needs to fire this
    /// session), but `createRoutineFromTool` uses `persisted` to decide
    /// whether it's honest to tell the model this actually worked.
    @discardableResult
    func addRoutine(instruction: String, schedule: Routine.Schedule, targetGroupID: String? = nil) -> (routine: Routine, persisted: Bool) {
        let routine = Routine(instruction: instruction, schedule: schedule, targetGroupID: targetGroupID)
        routines.append(routine)
        let persisted = RoutineStore.save(id: id, routines)
        scheduleTimer(for: routine)
        return (routine, persisted)
    }

    /// The Settings sheet's manual-edit entry point — same
    /// partial-update semantics and duplicate/persistence guards as
    /// `editRoutineFromTool`, just typed for direct UI use instead of
    /// raw tool arguments. Returns `false` on either a duplicate
    /// collision or a failed disk write; the UI shows an alert either
    /// way rather than pretending the change took.
    @discardableResult
    func updateRoutine(
        id routineID: String,
        instruction: String,
        schedule: Routine.Schedule,
        targetGroupID: String?
    ) -> Bool {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return false }
        var updated = routines[index]
        updated.instruction = instruction
        updated.schedule = schedule
        updated.targetGroupID = targetGroupID

        let key = Self.duplicateKey(instruction: updated.instruction, schedule: updated.schedule, targetGroupID: updated.targetGroupID)
        if routines.contains(where: { $0.id != routineID && Self.duplicateKey(instruction: $0.instruction, schedule: $0.schedule, targetGroupID: $0.targetGroupID) == key }) {
            return false
        }

        let previous = routines[index]
        routines[index] = updated
        guard RoutineStore.save(id: id, routines) else {
            routines[index] = previous
            return false
        }
        scheduleTimer(for: updated)
        return true
    }

    func removeRoutine(at offsets: IndexSet) {
        let previous = routines
        // Keyed by routine id, not position — `compactMap` here can
        // drop an entry (a routine with no currently-active timer, e.g.
        // already disabled), which would desync a plain positional
        // `zip` against `offsets` on rollback below.
        let removedTimers: [(id: String, timer: Timer)] = offsets.compactMap { index in
            let routineID = routines[index].id
            guard let timer = routineTimers.removeValue(forKey: routineID) else { return nil }
            return (routineID, timer)
        }
        routines.remove(atOffsets: offsets)
        guard RoutineStore.save(id: id, routines) else {
            // Restores the routines AND re-registers their timers — a
            // failed save shouldn't leave this bot's schedule silently
            // different in memory than what's actually on disk, the
            // same class of bug `create_routine`'s own persistence
            // check exists to catch.
            routines = previous
            for (routineID, timer) in removedTimers {
                routineTimers[routineID] = timer
            }
            return
        }
        for (_, timer) in removedTimers { timer.invalidate() }
    }

    /// The `create_routine` tool's entry point — raw tool arguments in,
    /// since `ToolRegistry` (a different module) doesn't know `Routine`'s
    /// shape. Returns a plain dict either way so the model gets a clear
    /// error to react to on bad input rather than a silent no-op.
    func createRoutineFromTool(_ arguments: [String: AnyCodable]) -> [String: Any] {
        guard let instruction = arguments["instruction"]?.asString, !instruction.isEmpty else {
            return ["error": "create_routine requires non-empty 'instruction'"]
        }
        guard let scheduleType = arguments["schedule_type"]?.asString else {
            return ["error": "create_routine requires 'schedule_type' (one of once, daily, interval_minutes)"]
        }

        let (parsedSchedule, scheduleError) = Self.parseSchedule(scheduleType: scheduleType, arguments: arguments)
        guard let schedule = parsedSchedule else { return ["error": scheduleError ?? "invalid schedule"] }

        var targetGroupID: String?
        if let groupName = arguments["target_group"]?.asString, !groupName.isEmpty {
            let (groupID, groupError) = resolveTargetGroup(named: groupName)
            guard let groupID else { return ["error": groupError ?? "invalid target_group"] }
            targetGroupID = groupID
        }

        // Idempotent on purpose: a model that calls this with the exact
        // same arguments more than once (retrying because it didn't
        // register the first call's own success — observed in practice,
        // 3 real duplicate routines created before the loop-detection
        // abort even kicked in) should get the SAME routine back, not a
        // fresh duplicate each time. This is the actual fix for that;
        // `remove_routine`'s auto-dedupe (and the routines skill's
        // "check list_routines first" guidance) are the cleanup net for
        // duplicates that already existed before this existed.
        let key = Self.duplicateKey(instruction: instruction, schedule: schedule, targetGroupID: targetGroupID)
        if let existing = routines.first(where: { Self.duplicateKey(instruction: $0.instruction, schedule: $0.schedule, targetGroupID: $0.targetGroupID) == key }) {
            return [
                "created": false, "already_existed": true, "id": existing.id,
                "next_fire": existing.schedule.nextFireDate(lastFiredAt: existing.lastFiredAt).map(ISO8601DateFormatter().string(from:)) ?? "never",
            ]
        }

        let (routine, persisted) = addRoutine(instruction: instruction, schedule: schedule, targetGroupID: targetGroupID)
        guard persisted else {
            // Roll the in-memory add back out rather than leaving a
            // routine that's live for this session but silently gone
            // the moment the app restarts — telling the model it
            // failed is more honest than a "created: true" that only
            // held true until the next relaunch.
            routines.removeAll { $0.id == routine.id }
            routineTimers.removeValue(forKey: routine.id)?.invalidate()
            return ["error": "failed to save the routine to disk — nothing was actually scheduled"]
        }
        return ["created": true, "id": routine.id, "next_fire": schedule.nextFireDate().map(ISO8601DateFormatter().string(from:)) ?? "never"]
    }

    /// Shared by `createRoutineFromTool` and `editRoutineFromTool` — one
    /// definition of "is this a valid schedule" so the two can't drift
    /// apart the way they would as two separate copy-pasted switches.
    /// Plain tuples rather than `Swift.Result` — a bare `String` doesn't
    /// conform to `Error`, and wrapping every message in a dedicated
    /// error type just for this would be more ceremony than the two
    /// call sites below are worth.
    private static func parseSchedule(scheduleType: String, arguments: [String: AnyCodable]) -> (schedule: Routine.Schedule?, error: String?) {
        switch scheduleType {
        case "once":
            guard let atString = arguments["at"]?.asString,
                  let at = ISO8601DateFormatter().date(from: atString) else {
                return (nil, "schedule_type 'once' requires 'at' as an ISO 8601 date-time")
            }
            guard at > Date() else {
                return (nil, "'at' (\(atString)) is not in the future")
            }
            return (.once(at), nil)
        case "daily":
            guard let hour = arguments["hour"]?.asInt, (0...23).contains(hour),
                  let minute = arguments["minute"]?.asInt, (0...59).contains(minute) else {
                return (nil, "schedule_type 'daily' requires integer 'hour' (0-23) and 'minute' (0-59)")
            }
            return (.daily(hour: hour, minute: minute), nil)
        case "interval_minutes":
            guard let minutes = arguments["minutes"]?.asInt, minutes >= 1 else {
                return (nil, "schedule_type 'interval_minutes' requires integer 'minutes' >= 1")
            }
            return (.interval(minutes: minutes), nil)
        default:
            return (nil, "unknown schedule_type '\(scheduleType)' — use once, daily, or interval_minutes")
        }
    }

    /// Shared by `createRoutineFromTool` and `editRoutineFromTool` — a
    /// non-empty `target_group` must name a group this bot is actually
    /// in, checked the same way both places.
    private func resolveTargetGroup(named groupName: String) -> (groupID: String?, error: String?) {
        guard let group = botDirectory.group(named: groupName) else {
            return (nil, "no group chat named '\(groupName)'")
        }
        guard group.memberBotIDs.contains(id) else {
            return (nil, "you're not a member of '\(groupName)' — add yourself first with add_bot_to_group")
        }
        return (group.id, nil)
    }

    /// The `edit_routine` tool's entry point — changes only the fields
    /// actually provided, leaving everything else as it was. Exists so
    /// a small correction (wrong time, a typo in the instruction) doesn't
    /// mean `remove_routine` + `create_routine` — losing `lastFiredAt`
    /// and getting a new id — for what was really just an edit.
    func editRoutineFromTool(_ arguments: [String: AnyCodable]) -> [String: Any] {
        guard let routineID = arguments["id"]?.asString, !routineID.isEmpty else {
            return ["error": "edit_routine requires 'id' — see list_routines for exact ids"]
        }
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else {
            return ["error": "no routine with id '\(routineID)' — see list_routines for current ids"]
        }
        var updated = routines[index]

        if let instruction = arguments["instruction"]?.asString {
            guard !instruction.isEmpty else { return ["error": "'instruction' can't be empty"] }
            updated.instruction = instruction
        }

        if let scheduleType = arguments["schedule_type"]?.asString {
            let (parsedSchedule, scheduleError) = Self.parseSchedule(scheduleType: scheduleType, arguments: arguments)
            guard let schedule = parsedSchedule else { return ["error": scheduleError ?? "invalid schedule"] }
            updated.schedule = schedule
        }

        if let groupName = arguments["target_group"]?.asString {
            if groupName.isEmpty {
                // Explicit empty string clears it back to this bot's own
                // chat — distinct from the field being omitted entirely,
                // which leaves whatever target it already had alone.
                updated.targetGroupID = nil
            } else {
                let (groupID, groupError) = resolveTargetGroup(named: groupName)
                guard let groupID else { return ["error": groupError ?? "invalid target_group"] }
                updated.targetGroupID = groupID
            }
        }

        if let isEnabled = arguments["enabled"]?.asBool {
            updated.isEnabled = isEnabled
        }

        // Same exact-duplicate guard `createRoutineFromTool` has —
        // editing one routine into an exact match of a DIFFERENT
        // existing one is just as much a duplicate as creating one
        // outright would be.
        let key = Self.duplicateKey(instruction: updated.instruction, schedule: updated.schedule, targetGroupID: updated.targetGroupID)
        if let collision = routines.first(where: { $0.id != routineID && Self.duplicateKey(instruction: $0.instruction, schedule: $0.schedule, targetGroupID: $0.targetGroupID) == key }) {
            return ["error": "this change would make it an exact duplicate of routine '\(collision.id)' — use that one instead, or remove_routine to clean it up"]
        }

        let previous = routines[index]
        routines[index] = updated
        guard RoutineStore.save(id: id, routines) else {
            routines[index] = previous
            return ["error": "failed to save to disk — nothing was actually changed"]
        }
        scheduleTimer(for: updated)
        return ["updated": true, "id": updated.id, "next_fire": updated.schedule.nextFireDate(lastFiredAt: updated.lastFiredAt).map(ISO8601DateFormatter().string(from:)) ?? "never"]
    }

    /// The `list_routines` tool — this bot's own current routines, read
    /// live rather than relying on the snapshot baked into the system
    /// prompt at the start of this run (see `fullSystemPrompt`), which
    /// goes stale the moment `create_routine` is called mid-run: the
    /// prompt already sent to the model doesn't retroactively update.
    /// Exists specifically so a bot can verify a routine actually got
    /// created (or check what's already scheduled before adding a
    /// duplicate) without misusing `recall_memory` — a bot's memory
    /// list and its routines are two different things.
    func listRoutinesForTool() -> [[String: Any]] {
        routines.map { routine in
            var entry: [String: Any] = [
                "id": routine.id,
                "instruction": routine.instruction,
                "schedule": routine.schedule.summary,
                "enabled": routine.isEnabled,
            ]
            if let next = routine.schedule.nextFireDate(lastFiredAt: routine.lastFiredAt) {
                entry["next_fire"] = ISO8601DateFormatter().string(from: next)
            }
            if let lastFiredAt = routine.lastFiredAt {
                entry["last_fired"] = ISO8601DateFormatter().string(from: lastFiredAt)
            }
            if let groupID = routine.targetGroupID {
                entry["target_group"] = botDirectory.group(id: groupID)?.name ?? "(deleted group)"
            }
            return entry
        }
    }

    /// The `remove_routine` tool's entry point. With `id`, removes that
    /// specific routine (see `list_routines` for exact ids). Without one,
    /// auto-detects and removes DUPLICATE routines instead — this is the
    /// part that actually matters in practice: the recurring failure
    /// mode observed wasn't "how do I remove a routine," it was the same
    /// routine getting (re)created across several attempts with nothing
    /// ever cleaning up the earlier ones. `duplicateRoutinesToRemove`
    /// keeps the first of each duplicate set and flags the rest.
    func removeRoutineFromTool(_ arguments: [String: AnyCodable]) -> [String: Any] {
        if let routineID = arguments["id"]?.asString, !routineID.isEmpty {
            guard let index = routines.firstIndex(where: { $0.id == routineID }) else {
                return ["error": "no routine with id '\(routineID)' — see list_routines for current ids"]
            }
            let removed = routines[index]
            let removedTimer = routineTimers.removeValue(forKey: removed.id)
            routines.remove(at: index)
            // Checked, unlike before — reporting "removed": true when
            // the write actually failed is the same truthfulness gap
            // `create_routine`'s own persistence check was added to
            // close, just on the deletion side instead of creation.
            guard RoutineStore.save(id: id, routines) else {
                routines.insert(removed, at: index)
                if let removedTimer { routineTimers[removed.id] = removedTimer }
                return ["error": "failed to save to disk — '\(removed.id)' wasn't actually removed"]
            }
            removedTimer?.invalidate()
            return ["removed": true, "id": removed.id, "instruction": removed.instruction]
        }

        let duplicates = Self.duplicateRoutinesToRemove(in: routines)
        guard !duplicates.isEmpty else {
            return ["removed": false, "reason": "no 'id' given, and no duplicate routines found to clean up"]
        }
        let previous = routines
        let duplicateIDs = Set(duplicates.map(\.id))
        let removedTimers: [(id: String, timer: Timer)] = duplicates.compactMap { dup in
            guard let timer = routineTimers.removeValue(forKey: dup.id) else { return nil }
            return (dup.id, timer)
        }
        routines.removeAll { duplicateIDs.contains($0.id) }
        guard RoutineStore.save(id: id, routines) else {
            routines = previous
            for (dupID, timer) in removedTimers { routineTimers[dupID] = timer }
            return ["error": "failed to save to disk — nothing was actually removed"]
        }
        for (_, timer) in removedTimers { timer.invalidate() }
        return ["removed": true, "duplicates_removed": duplicates.map { ["id": $0.id, "instruction": $0.instruction] }]
    }

    /// Two routines count as duplicates when they'd fire the exact same
    /// action at the exact same cadence for the exact same target — same
    /// (trimmed, case-insensitive) instruction, same schedule shape, same
    /// destination (own chat vs. a specific group). Exact on purpose, not
    /// fuzzy matching: a false-positive "duplicate" risks silently
    /// deleting a routine that was actually meant to be distinct. Keeps
    /// the FIRST occurrence of each set and returns the rest — the ones
    /// actually worth removing.
    private static func duplicateRoutinesToRemove(in routines: [Routine]) -> [Routine] {
        var seenKeys: Set<String> = []
        var toRemove: [Routine] = []
        for routine in routines {
            let key = duplicateKey(instruction: routine.instruction, schedule: routine.schedule, targetGroupID: routine.targetGroupID)
            if seenKeys.contains(key) {
                toRemove.append(routine)
            } else {
                seenKeys.insert(key)
            }
        }
        return toRemove
    }

    /// Shared by `duplicateRoutinesToRemove` (after-the-fact cleanup) and
    /// `createRoutineFromTool` (preventing the duplicate from ever being
    /// created) — one definition of "same routine" so the two can't drift.
    private static func duplicateKey(instruction: String, schedule: Routine.Schedule, targetGroupID: String?) -> String {
        "\(instruction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(schedule.summary)|\(targetGroupID ?? "")"
    }

    /// The `get_profile` tool — this bot's own current settings, read
    /// back as structured data instead of the model having to recall or
    /// re-derive them from the prose in its own system prompt, which
    /// (like `listRoutinesForTool`'s target) is fixed at the start of
    /// this run and won't reflect a setting changed since — e.g. from a
    /// group turn or delegation, where this is the ONLY way to check.
    func getProfileForTool() -> [String: Any] {
        [
            "name": name,
            "tagline": tagline,
            "model": selectedModel,
            "color_hex": colorHex,
            "skills": availableSkills.filter { selectedSkillIDs.contains($0.id) }.map(\.id),
            "memory_count": memories.count,
            "routine_count": routines.count,
            "groups": botDirectory.allGroups().filter { $0.memberBotIDs.contains(id) }.map(\.name),
        ]
    }

    /// Called right before this bot is permanently deleted
    /// (`ContentView.deleteBotPermanently`) — without this, a routine
    /// whose `Timer` is still pending fires into a bot that no longer
    /// exists in the sidebar, recreating its just-deleted
    /// `RoutineStore`/`TranscriptStore` files out from under the
    /// deletion that was supposed to be permanent.
    func invalidateAllRoutineTimers() {
        for timer in routineTimers.values { timer.invalidate() }
        routineTimers.removeAll()
    }

    /// (Re)schedules the in-process `Timer` for one routine — cancels any
    /// existing timer for its id first, so this is safe to call again after
    /// a routine fires (to pick up its next occurrence) or after editing it.
    private func scheduleTimer(for routine: Routine, quiet: Bool = false) {
        routineTimers.removeValue(forKey: routine.id)?.invalidate()
        guard routine.isEnabled, let next = routine.schedule.nextFireDate(lastFiredAt: routine.lastFiredAt) else { return }
        // `next` can already be `<= now` — a missed occurrence
        // (`nextFireDate` returns `now` for those) — in which case this
        // just fires it almost immediately instead of silently deferring
        // to the next regular occurrence.
        let interval = max(1, next.timeIntervalSinceNow)
        let missed = next.timeIntervalSinceNow <= 0
        if !quiet {
            logRoutine(
                missed
                    ? "\(routineLabel(routine)) was missed — catching up, firing in ~1s"
                    : "\(routineLabel(routine)) scheduled for \(next.formatted(date: .abbreviated, time: .standard)) (in \(Int(interval))s)"
            )
        }
        // A `Timer`'s clock stops while the Mac sleeps, so a day-long wait would come due hours late
        // (a daily stand-up that seemed to run only once). Wait at most a few minutes, then check the
        // wall clock again.
        let wait = min(interval, Self.routineRecheckInterval)
        routineTimers[routine.id] = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.routineTimerFired(id: routine.id) }
        }
    }

    static let routineRecheckInterval: TimeInterval = 300

    private func routineTimerFired(id routineID: String) {
        guard let routine = routines.first(where: { $0.id == routineID }), routine.isEnabled,
              let next = routine.schedule.nextFireDate(lastFiredAt: routine.lastFiredAt) else { return }
        if next.timeIntervalSinceNow > 1 {
            scheduleTimer(for: routine, quiet: true)
        } else {
            fireRoutine(id: routineID)
        }
    }

    private func routineLabel(_ routine: Routine) -> String {
        let preview = routine.instruction.count > 60 ? routine.instruction.prefix(60) + "…" : Substring(routine.instruction)
        return "Routine [\(routine.schedule.summary)] \"\(preview)\" (\(routine.id.prefix(8)))"
    }

    /// Routine lifecycle lines (scheduled / fired / deferred / retired) for
    /// the debug console, tagged `context: "routine"`. Without these, a
    /// fired routine's own-chat run is indistinguishable in the feed from
    /// the user typing the same text.
    private func logRoutine(_ text: String, kind: DebugLogEntry.Kind = .status) {
        guard DebugSettings.shared.isEnabled else { return }
        DebugLog.shared.log(bot: name, colorHex: colorHex, kind: kind, context: "routine", text: text)
    }

    /// Queues the routine's instruction exactly like an incoming user
    /// message (own 1:1 chat), or — if `targetGroupID` is set — fires it
    /// as a directed action in that group instead (see
    /// `GroupChatSession.fireRoutine`). Either way, then retires the
    /// routine (`.once`, spent) or reschedules it for its next occurrence.
    private func fireRoutine(id routineID: String) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        let routine = routines[index]
        guard sandbox != nil else {
            // The sandbox isn't ready yet — most likely the app just
            // launched and is still booting. `queueMessage` silently
            // no-ops with nothing queued when there's no sandbox, and
            // without this check the code below would still mark this
            // occurrence as fired (or, for a `.once` routine, remove it
            // outright) despite the instruction never actually being
            // delivered anywhere. Retry shortly instead of losing it.
            logRoutine("\(routineLabel(routine)) is due but the sandbox isn't ready — retrying in 30s", kind: .error)
            routineTimers[routineID] = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.fireRoutine(id: routineID) }
            }
            return
        }
        deliverRoutine(routine)

        if case .once = routine.schedule {
            logRoutine("\(routineLabel(routine)) was one-time — removed after firing")
            routines.remove(at: index)
            routineTimers.removeValue(forKey: routineID)?.invalidate()
        } else {
            routines[index].lastFiredAt = Date()
            scheduleTimer(for: routines[index])
        }
        RoutineStore.save(id: id, routines)
    }

    /// Sends a routine's instruction where it goes: its target group, or this bot's own chat.
    private func deliverRoutine(_ routine: Routine) {
        if let groupID = routine.targetGroupID, let group = botDirectory.group(id: groupID) {
            logRoutine("FIRED \(routineLabel(routine)) → group \"\(group.name)\"")
            Task { await group.fireRoutine(for: self, instruction: routine.instruction) }
        } else {
            logRoutine(
                "FIRED \(routineLabel(routine)) → own chat"
                    + (routine.targetGroupID != nil ? " (target group no longer exists)" : "")
            )
            // No target group, or it's since been deleted — falls back
            // to the bot's own chat rather than silently dropping the
            // routine's instruction.
            queueMessage(routine.instruction)
        }
    }

    /// The settings "Run now" button: delivers the routine once without touching its schedule.
    func runRoutineNow(id routineID: String) {
        guard let routine = routines.first(where: { $0.id == routineID }), sandbox != nil else { return }
        logRoutine("Run now: \(routineLabel(routine))")
        deliverRoutine(routine)
    }

    // MARK: - Bot-to-bot messaging

    /// The `list_bots` tool.
    func listOtherBots() -> [[String: Any]] {
        botDirectory.directory(excluding: id).map { ["name": $0.name, "role": $0.role] }
    }

    /// The `message_bot` tool — delegates to another bot by name and waits
    /// for its answer. Deliberately NOT the same thing as sending it a
    /// normal chat message: this never touches the recipient's own
    /// `displayMessages`/`messageQueue`/main `AgentRuntime`, so a
    /// delegated task can't get interleaved with whatever its own user is
    /// separately chatting with it about — see `handleDelegatedTask`.
    ///
    /// Both the request and the reply are appended to `InterBotStore`'s
    /// shared thread for this pair, and a "Messaged <name>…" notice lands
    /// in MY OWN transcript (not the recipient's) — the user sees that
    /// notice here and can tap it to read the full exchange, but the
    /// recipient's own chat is untouched by any of this.
    static let delegationBootWaitSeconds = 90

    struct RecentDelegation { let peerID: String; let message: String; let reply: String; let tainted: Bool; let at: Date }
    var recentDelegations: [RecentDelegation] = []

    /// `git fetch` in every repository under /workspace, best effort: lets a review start from current remote state.
    /// Returns a short note of what was fetched, or nil if there was nothing to do or it could not run.
    func refreshCheckouts() async -> String? {
        guard let sandbox, let handle else { return nil }
        let command = "cd /workspace 2>/dev/null || exit 0; n=0; for d in */.git; do [ -e \"$d\" ] || continue; "
            + "timeout 25 git -C \"${d%/.git}\" fetch --all --prune --quiet >/dev/null 2>&1; n=$((n+1)); done; echo $n"
        guard let result = try? await sandbox.exec(handle.id, command: command, timeout: 60, env: nil),
              let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else { return nil }
        return "\(count) repo\(count == 1 ? "" : "s")"
    }

    func delegateToBot(named name: String, message: String, quickIfBusy: Bool = false, senderTainted: Bool = false) async -> [String: Any] {
        guard let recipient = botDirectory.bot(named: name, excluding: id) else {
            return ["error": "No other bot named '\(name)'. Use list_bots to see who's available."]
        }
        // A bot that was just created (or the app just launched) is still booting its sandbox: wait
        // for it rather than failing and leaving the model to retry in a loop. A failed boot answers at once.
        var waited = 0
        while recipient.sandbox == nil || recipient.handle == nil, waited < Self.delegationBootWaitSeconds, !Task.isCancelled {
            if case .failed = recipient.state { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        guard recipient.sandbox != nil, recipient.handle != nil else {
            if case .failed(let why) = recipient.state {
                return ["error": "\(recipient.name)'s computer failed to start (\(why)). Tell your user; they can reset it in that bot's settings."]
            }
            return ["error": "\(recipient.name) is still starting up after \(waited) s. Tell your user and try again in a few minutes; don't retry in a loop."]
        }

        // The same request to the same bot again, soon after it answered: a delegation loop. Hand back the answer
        // already received instead of starting another run on the recipient.
        let now = Date()
        recentDelegations = recentDelegations.filter { now.timeIntervalSince($0.at) < 600 }
        if let earlier = recentDelegations.last(where: { $0.peerID == recipient.id && ReplyQuality.isDuplicate(message, of: [$0.message], threshold: 0.8) }) {
            return ["from": recipient.name, "reply": earlier.reply, "_tainted": earlier.tainted, "already_asked": true,
                    "note": "You asked \(recipient.name) this \(Int(now.timeIntervalSince(earlier.at))) s ago; this is the answer you got, not a new run. "
                        + "Do not ask again. Act on it, or ask something different (what changed, a specific file or command)."]
        }

        InterBotStore.append(InterBotMessage(fromBotID: id, fromBotName: self.name, toBotID: recipient.id, toBotName: recipient.name, text: message))
        displayMessages.append(DisplayMessage(
            role: .assistant, text: "Messaged \(recipient.name)…",
            interBotPeerID: recipient.id, interBotPeerName: recipient.name
        ))
        persistTranscript()

        // From a group turn or routine, the sender is itself mid-run. If the recipient is busy too, waiting for
        // its run could deadlock (two bots waiting on each other) or stall the group, so it answers right
        // away from what it already knows instead.
        let answeredQuickly = quickIfBusy && recipient.isBusy
        let (reply, replyTainted) = answeredQuickly
            ? await recipient.answerFromWhatIKnow(fromBotName: self.name, question: message, senderTainted: senderTainted)
            : await recipient.handleDelegatedTask(fromBotName: self.name, message: message, senderTainted: senderTainted)
        InterBotStore.append(InterBotMessage(fromBotID: recipient.id, fromBotName: recipient.name, toBotID: id, toBotName: self.name, text: reply))

        // Written to BOTH sides' own durable memory (`remember`'s same
        // mechanism, `addMemory`) unconditionally, not left to either
        // bot's own judgment — a delegation crossing between two bots
        // is exactly the kind of fact that's easy for either side to
        // lose track of, especially since each one only ever sees this
        // from its own half of the exchange. Truncated on both ends:
        // this is a "we talked about this, here's the gist" pointer,
        // not a second copy of the full exchange (that already lives in
        // `InterBotStore`, reachable via the "Messaged <name>…" notice).
        // Gated on `isSubstantiveDelegationReply` — a failed/aborted/
        // silent delegation isn't a fact worth remembering, and without
        // this check it'd get written verbatim, e.g. "they answered:
        // (stopped early: repeated the same 'X' call too many times)",
        // as if that error text were a real answer.
        // A reply produced by a run that read untrusted content could carry
        // injected instructions; don't write it into either bot's durable
        // memory (docs/GUARDRAILS.md, L2).
        if !replyTainted, Self.isSubstantiveDelegationReply(reply) {
            addMemory("Asked \(recipient.name): \"\(Self.truncatedForMemory(message))\" — they answered: \"\(Self.truncatedForMemory(reply))\"", source: "delegation")
            recipient.addMemory("\(self.name) asked me: \"\(Self.truncatedForMemory(message))\" — I answered: \"\(Self.truncatedForMemory(reply))\"", source: "delegation")
        }

        if !answeredQuickly, Self.isSubstantiveDelegationReply(reply) {
            recentDelegations.append(RecentDelegation(peerID: recipient.id, message: message, reply: reply, tainted: replyTainted, at: Date()))
        }
        var result: [String: Any] = ["from": recipient.name, "reply": reply, "_tainted": replyTainted]
        if answeredQuickly {
            result["note"] = "\(recipient.name) was busy with another task, so this answer comes from what it already knew "
                + "(no new commands were run). If you need it to check or do something, ask again once it's free, or @mention it in the group."
        }
        return result
    }

    private static func truncatedForMemory(_ text: String, limit: Int = 160) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    /// Filters out the known placeholder/error/abort strings
    /// `runIsolatedTask` can return in place of a genuine answer (see
    /// `handleDelegatedTask`) — an empty sandbox, a cancelled-while-
    /// queued run, a budget/loop abort, the default "didn't produce a
    /// response" fallback, or the `[[silent]]` sentinel (meant for
    /// group turns, not delegations, but `finish_task`'s `outcome:
    /// "silent"` isn't actually restricted to that context). None of
    /// these are an answer worth either bot remembering.
    private static func isSubstantiveDelegationReply(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[[silent]]" else { return false }
        if trimmed.hasPrefix("(stopped early:") { return false }
        let knownPlaceholders = [
            "has no running sandbox to work with right now.",
            "didn't produce a response.)",
            "task was cancelled before its turn came up.",
        ]
        return !knownPlaceholders.contains { trimmed.contains($0) }
    }

    /// The `create_bot` tool — delegates the actual creation to
    /// `botDirectory.createBot`, since only `ContentView` owns the
    /// sidebar's bot list and knows how to boot one. An optional
    /// `systemPrompt` override is applied here, after creation, since
    /// `BotDirectory`'s closure only knows about name/tagline.
    func createBot(named name: String, tagline: String, systemPrompt: String?) async -> [String: Any] {
        // Idempotent, same reasoning as `createRoutineFromTool`: a model
        // that calls this again with the same name (retrying because it
        // didn't register the first call's success) should get the
        // EXISTING bot back, not a second one — this one's expensive and
        // hard to undo (a whole new sandbox container), unlike most
        // other duplicate-call risks in this file.
        if let existing = botDirectory.allBots().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return ["created": false, "already_existed": true, "id": existing.id, "name": existing.name, "tagline": existing.tagline]
        }
        let model = selectedModel, vision = modelHasVision, isLocal = modelProvider == .ollama
        guard let newBot = botDirectory.createBot(name, tagline, { newBot in
            // The role prompt becomes the new bot's custom instructions; the
            // built-in prompt (tools, finish_task rule) is always applied on top.
            if let systemPrompt, !systemPrompt.isEmpty {
                newBot.systemPromptText = systemPrompt
            }
            // Same local model as the bot that recruited it: the hard-coded default may not even be
            // installed. (A remote provider's API key is stored per bot, so that isn't carried over.)
            if isLocal {
                newBot.selectedModel = model
                newBot.modelHasVision = vision
            }
        }) else {
            return ["error": "couldn't create a new bot right now"]
        }
        return ["id": newBot.id, "name": newBot.name, "tagline": newBot.tagline, "model": newBot.selectedModel,
                "note": "\(newBot.name) is starting its own computer in the background (usually under a minute). "
                    + "message_bot waits for it, so you can brief it right away."]
    }

    /// The `add_bot_to_group` tool — `botName` can be this bot's own name
    /// (self-add) or another's; either way resolved through the same
    /// directory lookup `message_bot` uses.
    func addBotToGroup(botName: String, groupName: String) async -> [String: Any] {
        guard let target = botDirectory.bot(named: botName, excluding: "") else {
            return ["error": "No bot named '\(botName)'. Use list_bots to see who's available."]
        }
        // Checked first, separately from the closure's plain `Bool` —
        // `GroupChatSession.addMember` already no-ops safely on a repeat
        // add, but without this the tool reported the SAME generic
        // "no group / full" error whether the group genuinely didn't
        // exist or the bot was just already in it, which would mislead
        // a model retrying after its own first call already succeeded.
        if let group = botDirectory.group(named: groupName), group.memberBotIDs.contains(target.id) {
            return ["added": true, "already_member": true, "bot": target.name, "group": groupName]
        }
        guard botDirectory.addBotToGroup(target, groupName) else {
            return ["error": "No group named '\(groupName)', or it's already at the 6-member cap."]
        }
        return ["added": true, "bot": target.name, "group": groupName]
    }

    /// The `update_user` tool — drops a status line into THIS bot's own 1:1
    /// chat from wherever it's working (group turn, delegation, routine).
    /// Display-only: doesn't queue a model turn, so it can't loop. Kept in
    /// `displayMessages`, so it's also part of the history a rebuilt
    /// runtime is seeded with — the bot remembers it told the user.
    func postUpdateToUser(_ message: String, source: String) -> [String: Any] {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ["error": "update_user requires a non-empty 'message'"] }
        displayMessages.append(DisplayMessage(role: .assistant, text: "(Update from \(source)) \(text)"))
        persistTranscript()
        hasUnread = true
        return ["posted": true]
    }

    /// `get_bot_instructions` / `set_bot_instructions`: read or change a bot's user-added instructions (its own, or
    /// another bot's). The user has already approved a change (`ToolGate.alwaysAsksUser`); a run that read untrusted
    /// content can't change any, since that is how an injected instruction would make itself permanent.
    func botInstructionsForTool(botName: String?, mode: String, text: String?, untrusted: Bool) -> [String: Any] {
        let trimmedName = botName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target: Bot?
        if trimmedName.isEmpty || trimmedName.caseInsensitiveCompare(name) == .orderedSame { target = self }
        else { target = botDirectory.allBots().first { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame } }
        guard let target else {
            return ["error": "No bot named \(trimmedName). Bots: " + botDirectory.allBots().map(\.name).joined(separator: ", ")]
        }
        let current = target.systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "view" {
            return ["bot": target.name, "role": target.tagline, "instructions": current.isEmpty ? "(none: only the built-in rules)" : current]
        }
        guard !untrusted else {
            return ["error": "This run has read untrusted content, so it can't change any bot's instructions. Tell your user what "
                + "you'd change and why; they can edit it in the bot's settings."]
        }
        let addition = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty || mode == "replace" else { return ["error": "'text' is empty: nothing to add."] }
        if Self.looksLikeSecret(addition) {
            return ["error": "That text looks like it contains a credential. Instructions are plain prose; secrets go in the secret store."]
        }
        let updated = mode == "replace" ? addition : (current.isEmpty ? addition : current + "\n\n" + addition)
        guard updated.count <= Self.maxCustomInstructions else {
            return ["error": "Too long: instructions are capped at \(Self.maxCustomInstructions) characters (this would be \(updated.count)). "
                + "Use replace with a tighter version."]
        }
        target.systemPromptText = updated
        botDirectory.saveBots()
        let by = target === self ? "itself" : name
        _ = target.postUpdateToUser("My instructions were changed by \(by) (\(mode)). They now read:\n\n\(updated.isEmpty ? "(none)" : updated)",
                                    source: "instructions")
        return ["ok": true, "bot": target.name, "mode": mode, "instructions": updated,
                "note": target.isBusy ? "Saved. \(target.name)'s current run keeps the old ones; its next run uses these." : "Saved; \(target.name)'s next run uses these."]
    }

    static let maxCustomInstructions = 6000

    static func looksLikeSecret(_ text: String) -> Bool {
        let patterns = [#"gh[pousr]_[A-Za-z0-9]{20,}"#, #"\bsk-[A-Za-z0-9]{16,}"#, #"\bAIza[0-9A-Za-z_-]{30,}"#,
                        #"(?i)\b(password|passwd|api[_ ]?key|token)\s*[:=]\s*\S{8,}"#, #"://[^/\s]+:[^@\s]+@"#,
                        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// `post_screenshot` in the 1:1 chat: the image appears as this bot's message right away.
    func postImageToOwnChat(caption: String, data: Data) -> [String: Any] {
        guard let imageID = ChatImageStore.save(data) else { return ["error": "Couldn't save that image (too big, or not an image)."] }
        displayMessages.append(DisplayMessage(role: .assistant, text: caption, imageIDs: [imageID]))
        streamingIndex = nil
        persistTranscript()
        hasUnread = true
        return ["posted": true, "note": "The image is in the chat now. Don't describe it again at length."]
    }

    /// `post_screenshot` during a group turn: posted into that group as this bot's message.
    func postImageToGroup(groupName: String, caption: String, data: Data) -> [String: Any] {
        guard let group = botDirectory.group(named: groupName), group.memberBotIDs.contains(id) else {
            return ["error": "No group named '\(groupName)' that you're in."]
        }
        guard let imageID = ChatImageStore.save(data) else { return ["error": "Couldn't save that image (too big, or not an image)."] }
        group.postFromBot(self, text: caption, imageIDs: [imageID])
        return ["posted": true, "group": group.name, "note": "The image is in the group chat now. Don't describe it again at length."]
    }

    /// The `post_to_group` tool — posts `message` into a group this bot is
    /// already a member of, immediately and verbatim.
    func postToGroup(groupName: String, message: String) -> [String: Any] {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ["error": "post_to_group requires a non-empty 'message'"] }
        guard let group = botDirectory.group(named: groupName) else {
            return ["error": "No group named '\(groupName)'."]
        }
        guard group.memberBotIDs.contains(id) else {
            return ["error": "You're not a member of '\(group.name)' — add yourself first with add_bot_to_group."]
        }
        group.postFromBot(self, text: text)
        return ["posted": true, "group": group.name]
    }

    /// Runs one isolated task on behalf of another bot's delegation — a
    /// fresh `AgentRuntime` using THIS bot's own system prompt, skills,
    /// model, and sandbox, seeded with no history (a delegated ask is its
    /// own thing, not mixed into whatever this bot's own user is
    /// separately chatting about) and no `list_bots`/`message_bot` of its
    /// own, so a delegation can't recurse into a loop.
    ///
    /// Waits behind whatever else this bot is currently doing (own chat,
    /// another delegation, a group turn) — see `runIsolatedTask`'s run
    /// lock — before it actually starts.
    /// Answers another bot's question without a run (and without this bot's run lock): one fast-model call
    /// over what it already knows — role, memory, tasks, routines and its latest tool results.
    func answerFromWhatIKnow(fromBotName senderName: String, question: String, senderTainted: Bool = false) async -> (text: String, tainted: Bool) {
        var context = standupContext()
        if !lastTurnObservations.isEmpty {
            context += "\n\nWHAT YOUR TOOLS RETURNED IN YOUR LATEST RUN:\n" + EvidenceDigest.digest(lastTurnObservations, limit: 2_500)
        }
        let instruction = "\(senderName), another bot, asks: \"\(String(question.prefix(1_500)))\". You're busy with another task, so "
            + "answer from what you already know (below) in a few lines. Only state what the records show; if they don't "
            + "cover it, say so plainly and suggest asking again when you're free."
        let reply = await quickReplyInGroup(groupName: "a direct question", otherMembers: [senderName], transcript: "",
                                            instruction: instruction, extraContext: context, style: "a short, factual answer")
        let ownTaint = await runtime?.isTainted ?? false
        let tainted = senderTainted || ownTaint
        return (reply ?? "(\(name) is busy with another task and couldn't answer from what it knows; ask again shortly.)", tainted)
    }

    func handleDelegatedTask(fromBotName senderName: String, message: String, senderTainted: Bool = false) async -> (text: String, tainted: Bool) {
        let suffix = "You're handling this as a delegated request from another bot (\(senderName)), not a "
            + "direct message from your own user. Answer it directly and completely — \(senderName) will "
            + "relay your answer back to their user."
        // A request from a bot that has read untrusted content may carry injected instructions: this run starts untrusted too.
        let result = await runIsolatedTaskResult(systemPromptSuffix: suffix, goal: message, debugContext: "delegated from \(senderName)",
                                                 initialTaint: senderTainted ? [.peerBot] : [])
        return (result.text, result.tainted)
    }

    /// Cheap pre-check for an un-@mentioned group turn: one tiny tool-less
    /// model call (role + transcript only) instead of a full agent run with
    /// the whole system prompt and skills, for turns that usually end in
    /// silence anyway. Biased hard toward YES — any error, empty or
    /// ambiguous answer proceeds to the full run, so this can only ever
    /// skip a turn the bot itself clearly said it had nothing to add to.
    func wantsToRespondInGroup(groupName: String, transcript: String, goalContext: String? = nil) async -> Bool {
        await Telemetry.$context.withValue(TelemetryContext(bot: name, purpose: "reply gate")) {
            guard sandbox != nil else { return true }
            let checkSpan = BotActivity.shared.begin(bot: self, kind: .checking, detail: "reply check · \(groupName)")
            defer { BotActivity.shared.end(checkSpan) }
            let role = tagline.isEmpty ? String(systemPromptText.prefix(300)) : tagline
            let messages = [
                ChatMessage(role: .system, content: "You are \(name), a member of the group chat \"\(groupName)\". Your role: \(role)"),
                ChatMessage(role: .user, content: """
                    Recent group messages:
                    \(transcript)

                    \(goalContext.map { $0 + "\n\n" } ?? "")Should you reply to the latest message? Answer YES if it asks or invites anything of you or \
                    your role, or if you have something necessary to add that nobody has already said\(goalContext == nil ? "" : ", or if an open goal step is assigned to you or someone @mentioned you. Do NOT answer YES just because you could help, and never to start your own side investigation"). Answer \
                    NO only if it clearly has nothing to do with you or has already been fully handled. If \
                    unsure, answer YES. Reply with exactly one word: YES or NO.
                    """),
            ]
            if Reliability.isOn(.structuredGates), let decided = await structuredYesNo(system: messages[0].content, user: messages[1].content) {
                if DebugSettings.shared.isEnabled {
                    DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "group: \(groupName)",
                                        text: "reply gate (structured): \(decided ? "YES — running full turn" : "NO — skipped full turn")")
                }
                return decided
            }
            let (backend, fastModel) = await makeFastBackend()
            guard let reply = try? await backend.chat(messages: messages, tools: [], model: fastModel, temperature: 0),
                  !reply.message.content.isEmpty else { return true }
            let wants = ReplyGate.shouldReply(from: reply.message.content)
            if DebugSettings.shared.isEnabled {
                DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "group: \(groupName)",
                                    text: "reply gate: \(wants ? "YES — running full turn" : "NO — skipped full turn")")
            }
            return wants
        }
    }

    /// The cheap tier: a small fast model for gates, intake checks, small talk and helpers.
    /// Falls back to this bot's own backend/model when no fast model is set (or on a remote provider).
    private func debugLogReliability(_ text: String, groupName: String) {
        guard DebugSettings.shared.isEnabled else { return }
        DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "group: \(groupName)", text: text)
    }

    private func finishOwnChatLessonTrail() {
        let trail = ownChatLessonTrail
        ownChatLessonTrail = LessonTrail()
        guard trail.worthReviewing else { return }
        let task = displayMessages.last(where: { $0.role == .user })?.text ?? ""
        Task { @MainActor [weak self] in
            let tainted = await self?.runtime?.isTainted ?? true
            await self?.reviewRunForLesson(trail, task: task, tainted: tainted)
        }
    }

    /// Learning from experience: after a run that worked around a failure (or a long one), the fast model is
    /// asked whether it taught something reusable that this bot's skills and notes don't cover. If so, one line
    /// is remembered (source "learned", shown in the bot's Memory settings, where it can be edited or deleted).
    /// Never from a run with untrusted content in it: that text could plant a standing instruction.
    func reviewRunForLesson(_ trail: LessonTrail, task: String, tainted: Bool) async {
        guard trail.worthReviewing, !tainted, Date().timeIntervalSince(lastLessonReview) > 180 else { return }
        lastLessonReview = Date()
        let skills = availableSkills.filter { selectedSkillIDs.contains($0.id) }.map { (name: $0.id, description: $0.description) }
        let notes = memoryBook.core(limit: 25).map(\.text)
        let (backend, fastModel) = await makeFastBackend()
        let messages = LessonLearner.messages(task: task, trail: trail.text, skills: skills, notes: notes)
        guard let reply = try? await backend.chat(messages: messages, tools: [], model: fastModel, temperature: 0.2),
              let lesson = LessonLearner.lesson(from: reply.message.content) else { return }
        let saved = addMemory(lesson, source: "learned", importance: 3)
        if DebugSettings.shared.isEnabled {
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "memory",
                                text: saved ? "learned: \(lesson)" : "couldn't save the lesson: \(lesson)")
        }
    }

    /// The fast tier on a remote endpoint (Settings › Fast model), when one is set up.
    private func remoteFastBackend(timeout: TimeInterval) async -> (backend: any ModelBackend, model: String)? {
        guard ModelTiers.fastUsesRemote, let url = ModelTiers.fastRemoteBaseURL else { return nil }
        // Not answering at all (wrong address, switched off, blocked): use the local tier now, not after a 30 s wait.
        guard await ModelTiers.remoteReachable(url) else { return nil }
        let key = (try? await SecretStore().resolveOne(name: ModelTiers.fastRemoteAPIKeySecretName)) ?? nil
        let model = ModelTiers.fastRemoteModel
        if (key ?? "").isEmpty, let root = ModelTiers.ollamaRoot(url) {
            return (OllamaBackend(baseURL: root, defaultModel: model, timeout: timeout), model)
        }
        return (OpenAICompatibleBackend(baseURL: url, apiKey: key ?? "", defaultModel: model, timeout: timeout,
                                        reasoningEffort: ModelTiers.looksLikeOllama(url) ? "none" : nil), model)
    }

    private func makeFastBackend() async -> (backend: any ModelBackend, model: String) {
        await fastTier(remoteTimeout: 30, localTimeout: 120)
    }

    /// The fast tier: the remote fast model when one is set, else the local small model. A remote one that doesn't
    /// answer (down, hanging, rate-limited) hands over to the local tier for a few minutes, for every bot at once
    /// (`fastTierState`), instead of each gate and review waiting out its timeout.
    private func fastTier(remoteTimeout: TimeInterval, localTimeout: TimeInterval) async -> (backend: any ModelBackend, model: String) {
        let local: (backend: any ModelBackend, model: String)
        if modelProvider == .ollama {
            let model = ModelTiers.cheapModel(main: selectedModel)
            local = (OllamaBackend(defaultModel: model, timeout: localTimeout), model)
        } else {
            local = (await makeModelBackend(), selectedModel)
        }
        guard let remote = await remoteFastBackend(timeout: remoteTimeout) else { return local }
        let remoteName = remote.model
        let backend = FallbackBackend(primary: remote.backend, fallback: local.backend, fallbackModel: local.model,
                                      state: Self.fastTierState, retryDelays: []) { toFallback, reason in
            Task { @MainActor in
                guard DebugSettings.shared.isEnabled else { return }
                DebugLog.shared.log(bot: "Model", colorHex: "#888888", kind: .status, context: "fast model",
                                    text: toFallback
                                        ? "remote fast model \(remoteName) didn't answer (\(reason)); using the local fast model for a few minutes"
                                        : "remote fast model \(remoteName) is answering again")
            }
        }
        return (backend, remote.model)
    }

    /// Shared by every bot: the remote fast model is one service.
    static let fastTierState = FallbackState()

    /// `ask_helpers`: independent, tool-less sub-prompts answered in parallel by the fast tier.
    /// With Ollama's OLLAMA_NUM_PARALLEL > 1 they genuinely run at the same time.
    func runHelpers(_ tasks: [String]) async -> [String: Any] {
        await Telemetry.$context.withValue(TelemetryContext(bot: name, purpose: "helpers")) {
            let (backend, model) = await makeFastBackend()
            let system = "You are a focused helper for another AI agent. Answer ONLY the task given, concisely and "
                + "factually, using only the text provided. If something is missing, say what is missing."
            let answers = await withTaskGroup(of: (Int, String).self) { group -> [(Int, String)] in
                for (index, task) in tasks.enumerated() {
                    group.addTask {
                        let messages = [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: String(task.prefix(12_000)))]
                        do {
                            let reply = try await backend.chat(messages: messages, tools: [], model: model, temperature: 0.2)
                            var text = reply.message.content
                            if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
                            return (index, text.trimmingCharacters(in: .whitespacesAndNewlines))
                        } catch {
                            return (index, "(helper failed: \(error.localizedDescription))")
                        }
                    }
                }
                var out: [(Int, String)] = []
                for await item in group { out.append(item) }
                return out
            }
            let ordered = answers.sorted { $0.0 < $1.0 }.map { ["task": tasks[$0.0].prefix(80) + (tasks[$0.0].count > 80 ? "…" : ""), "answer": $0.1] }
            return ["results": ordered, "note": "Helper answers are unverified model output; check anything important."]
        }
    }

    /// A yes/no decision from the fast tier with the output constrained to {"answer":"YES"|"NO"} (Ollama
    /// structured outputs): no free text to misparse. nil when the backend can't do it, so callers fall back.
    private func structuredYesNo(system: String, user: String) async -> Bool? {
        let (backend, model) = await makeFastBackend()
        guard let ollama = backend as? OllamaBackend else { return nil }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string", "enum": ["YES", "NO"]]],
            "required": ["answer"],
        ]
        let messages = [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: user)]
        guard let raw = try? await ollama.chatStructured(messages: messages, model: model, schema: schema),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = (object["answer"] as? String)?.uppercased() else { return nil }
        return answer == "YES"
    }

    /// Fast path for small talk and short questions in a group: ONE tool-less model call with a
    /// compact prompt (no sandbox, no skills, no agent loop). Returns nil on any failure so the
    /// caller falls back to the full agent turn.
    func quickReplyInGroup(
        groupName: String, otherMembers: [String], transcript: String, instruction: String,
        extraContext: String = "", style: String = "warm, natural, 1-3 short sentences", includeMemory: Bool = true
    ) async -> String? {
        await Telemetry.$context.withValue(TelemetryContext(bot: name, purpose: "quick reply")) {
            let span = BotActivity.shared.begin(bot: self, kind: .running, detail: "quick reply · \(groupName)")
            defer { BotActivity.shared.end(span) }
            let persona = String(systemPromptText.prefix(700))
            var system = "You are \(name)" + (tagline.isEmpty ? "" : ", \(tagline)")
            system += ", in the group chat \"\(groupName)\" with \(otherMembers.joined(separator: ", ")). "
            if !persona.isEmpty { system += "Your persona:\n\(persona)\n\n" }
            let remembered = includeMemory ? memoryBook.core(limit: 6).map(\.text) : []
            if !remembered.isEmpty { system += "Things you remember:\n- " + remembered.joined(separator: "\n- ") + "\n\n" }
            system += "Reply in character as a chat message: \(style). Messages are labeled by sender. "
            system += "Never prefix your reply with your own name. Do not repeat what others already said."
            system += "\n\n" + BuiltInSystemPrompt.writingStyle
            let messages = [
                ChatMessage(role: .system, content: system),
                ChatMessage(role: .user, content: "Group chat so far:\n\(transcript)\n\n" + (extraContext.isEmpty ? "" : extraContext + "\n\n") + instruction),
            ]
            let (backend, fastModel) = await makeFastBackend()
            guard let reply = try? await backend.chat(messages: messages, tools: [], model: fastModel, temperature: 0.6) else { return nil }
            var text = reply.message.content
            if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip a self-label the model sometimes adds ("Bugbot: hi").
            if text.lowercased().hasPrefix(name.lowercased() + ":") {
                text = String(text.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            return (text.isEmpty || text.contains("[[silent]]")) ? nil : text
        }
    }

    /// A plain-language update after a run stopped early, written from what the tools actually returned:
    /// what was done and confirmed, what's left, what's needed. Never the internal stop reason verbatim.
    func stopUpdate(reason: String, evidence: String, transcript: String, audience: String, includeMemory: Bool) async -> String {
        let plain = Self.plainStopReason(reason)
        let instruction = "You had to stop before finishing your task (\(plain)). Write a short message to \(audience): what you did "
            + "and confirmed (ONLY from the tool output below; if there is none, say you didn't get to check anything), what's left, and "
            + "what you need from them to continue. Write naturally in 2-5 sentences: no headings, no labels like Verified/Open/Need, "
            + "no internal terms (guardrails, frozen, tokens, iterations). Do not invent results."
        let context = evidence.isEmpty ? "" : "WHAT YOUR TOOLS RETURNED:\n" + EvidenceDigest.digest(evidence, limit: 1_500)
        if let text = await quickReplyInGroup(groupName: "your current task", otherMembers: [], transcript: transcript,
                                              instruction: instruction, extraContext: context, style: "a short, honest status update",
                                              includeMemory: includeMemory) {
            return text
        }
        return "I had to stop before finishing (\(plain)). Ask me to pick it up again, or tell me how you'd like to proceed."
    }

    /// The stop reason in words a user understands.
    static func plainStopReason(_ reason: String) -> String {
        let r = reason.lowercased()
        if r.contains("guardrails froze") || r.contains("blocked") { return "a few of the commands I tried aren't allowed here" }
        if r.contains("max tokens") || r.contains("max iterations") || r.contains("wall-clock") { return "I ran out of room for this turn" }
        if r.contains("in a row failed") { return "several attempts in a row failed, so I stopped to check with you" }
        if r.contains("same result") || r.contains("repeated") || r.contains("circles") { return "I was repeating myself without making progress" }
        if r.contains("unreachable") { return "the model server wasn't reachable" }
        return "something stopped me partway"
    }

    private func logStop(_ reason: String, context: String) {
        guard DebugSettings.shared.isEnabled else { return }
        DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .error, context: context,
                            text: reason.hasPrefix("stopped early") ? reason : "stopped early: \(reason)")
    }

    /// The latest tool results from this bot's own-chat run, for `stopUpdate`.
    private func runtimeToolOutput() -> String? {
        lastOwnChatToolOutput.isEmpty ? nil : lastOwnChatToolOutput
    }

    /// What this bot knows about its own work, for a stand-up: its open tasks, scheduled routines and
    /// anything it was told to remember. Nothing is invented here; an empty section says so.
    func standupContext() -> String {
        var lines = ["YOUR OWN RECORDS (the only things you may report as yours beyond what is in the chat):"]
        lines.append(tasks.isEmpty ? "- Open tasks: none recorded."
                     : "- Open tasks: " + tasks.prefix(8).map(\.text).joined(separator: " | "))
        lines.append(routines.isEmpty ? "- Routines: none."
                     : "- Routines: " + routines.prefix(5).map { "\($0.schedule.summary): \($0.instruction.prefix(80))" }.joined(separator: " | "))
        if !memoryBook.entries.isEmpty { lines.append("- Remembered: " + memoryBook.core(limit: 4).map(\.text).joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }

    /// Cheap classifier for goal intake: is this user message an actionable
    /// request (work to be done) rather than a question, greeting, or chat?
    /// Errors resolve to `false` — no goal is safer than a spurious one.
    func looksLikeActionableRequest(_ text: String) async -> Bool {
        await Telemetry.$context.withValue(TelemetryContext(bot: name, purpose: "intake check")) {
            let checkSpan = BotActivity.shared.begin(bot: self, kind: .checking, detail: "goal intake check")
            defer { BotActivity.shared.end(checkSpan) }
            let messages = [
                ChatMessage(role: .system, content: "You classify chat messages. Reply with exactly one word."),
                ChatMessage(role: .user, content: """
                    Message from the user to a team of AI bots:
                    \(text)

                    Is this an actionable request that needs multi-step work by the team (build, install, fix, \
                    investigate, produce something)? Answer NO for questions, greetings, opinions, status \
                    checks, or casual chat. Reply with exactly one word: YES or NO.
                    """),
            ]
            if Reliability.isOn(.structuredGates), let decided = await structuredYesNo(system: messages[0].content, user: messages[1].content) { return decided }
            let (backend, fastModel) = await makeFastBackend()
            guard let reply = try? await backend.chat(messages: messages, tools: [], model: fastModel, temperature: 0) else { return false }
            return reply.message.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("YES")
        }
    }

    /// The owner's "where we are" post when a goal stalls.
    func stallSummary(groupName: String, goalBlock: String, transcript: String) async -> String? {
        let suffix = "You are the owner of the shared goal in the group chat \"\(groupName)\". Progress has stalled and the "
            + "team is paused. Post ONE short status message for the user: what has been achieved, what is blocking or "
            + "looping, and what you need from them (a decision, access, or a redirect). No @mentions of other members. "
            + "Put the message in finish_task's summary."
        let outcome = await runIsolatedTaskResult(
            systemPromptSuffix: suffix, goal: goalBlock + "\n\nRecent conversation:\n" + transcript,
            debugContext: "goal stalled: \(groupName)"
        )
        let reply = outcome.text
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return (outcome.failed || trimmed.isEmpty || trimmed == "[[silent]]") ? nil : reply
    }

    /// One turn in a group chat (see `GroupChatSession`) — same isolated
    /// mechanism as delegation, with the group's mention/silence rule
    /// instead of "delegated from another bot." Returns `nil` for a
    /// genuine `[[silent]]` (or an empty reply) — the group orchestrator
    /// drops those rather than posting an empty bubble.
    func respondInGroup(
        groupName: String, otherMembers: [String], transcriptSoFar: String,
        wasMentioned: Bool, mentionedByBot: Bool = false,
        extraSuffix: String = "",
        goalHandler: (@Sendable (String, [String: AnyCodable], Int) async -> [String: Any])? = nil,
        untrustedInput: Bool = false,
        withheldTools: [String] = [],
        plainReplyEndsTurn: Bool = false,
        onDraft: (@MainActor (String?) -> Void)? = nil
    ) async -> String? {
        let mustReply = wasMentioned && !mentionedByBot
        lastTurnFailure = nil
        let rule: String
        if mustReply {
            rule = "You were just @mentioned (by name, or via @everyone) by the user in this group chat — you MUST "
                + "post a substantive reply. Do not call finish_task with outcome: \"silent\"; put your actual "
                + "reply in the summary."
        } else if wasMentioned {
            rule = "Another bot just @mentioned you (or used @everyone). Reply if there's something for you to do, "
                + "answer, or add — do the work and post the result. If the message is only an acknowledgement, a "
                + "thank-you, or needs nothing from you, call finish_task with outcome: \"silent\" instead of "
                + "replying (the summary is never shown), so the exchange can end."
        } else {
            rule = "Only respond if you genuinely have something necessary to add given your own role here. If "
                + "not, call finish_task with outcome: \"silent\" (the summary you give it is never shown "
                + "to anyone, so a short internal note is fine). Do NOT call finish_task with outcome: "
                + "\"done\" and a summary explaining that you're staying quiet, like \"No action needed "
                + "from me right now\" or \"I'm waiting for X\" — that summary posts to the group as a real "
                + "message exactly like any other reply, which is the opposite of staying silent."
        }
        let goalRule = " Everyone here works asynchronously and replies as soon as they're done, so read the whole "
            + "transcript for what's already been said. If the shared goal isn't met yet and there's a next step, "
            + "do your part and @mention the specific member who should act next; when the goal is met, say so "
            + "plainly and stop @mentioning people."
        let suffix = "You're one of up to 6 bots in the group chat \"\(groupName)\", alongside: "
            + "\(otherMembers.joined(separator: ", ")). Every member works on its OWN separate Linux VM — nothing is shared "
            + "between them, so never call it a shared sandbox; to share a result, post it in the chat. "
            + "When you commit to doing something, record it with remember_task (one line) and call complete_task when it is done: "
            + "your stand-up report is built from that list. "
            + "Match your effort to the question: a simple question gets a direct answer with at most one or two tool calls; only a multi-part task justifies investigating. "
            + "Do not re-verify what the chat already establishes, and never state a version, path or number you did not see in a tool result or in the chat. "
            + "Messages below are labeled by who sent them. \(rule)\(goalRule)\(extraSuffix.isEmpty ? "" : "\n\n" + extraSuffix)"
        // Reply checks run inside the same run (see `runIsolatedTaskResult`'s
        // `followUp`): a correction goes to the runtime that already has the
        // tool results, instead of a fresh run that repeats all of the work.
        var outcome = await runIsolatedTaskResult(
            systemPromptSuffix: suffix, goal: transcriptSoFar, debugContext: "group: \(groupName)", goalHandler: goalHandler,
            untrustedInput: untrustedInput, plainReplyEndsTurn: plainReplyEndsTurn, allowBotMessaging: true,
            withheldTools: withheldTools,
            onDraft: onDraft,
            followUp: { [weak self] result in
                guard let self, !result.failed else { return nil }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Being called on (especially via @everyone) means every member answers.
                if mustReply, text == "[[silent]]" {
                    return "Staying silent is NOT allowed for this turn: you were explicitly called on. Post a short reply; "
                        + "if you truly have nothing to add, say that in one sentence. Call finish_task with outcome \"done\" and the reply as its summary."
                }
                guard Reliability.isOn(.replyChecks), text != "[[silent]]", !text.hasPrefix("(stopped early") else { return nil }
                // A reply that only announces what the bot is about to do is not an answer.
                if ReplyQuality.looksLikeNarration(result.text) {
                    return "Your reply was only an announcement (\"" + String(result.text.prefix(80)) + "…\"). Do the work now with "
                        + "your tools if needed, then call finish_task with the actual result as its summary: facts, numbers and outputs, not intentions."
                }
                // CRITIC-style check: every version, path or address stated must appear in what the tools returned or the chat.
                let allowed = self.lastTurnObservations + "\n" + transcriptSoFar + "\n" + extraSuffix + "\n" + self.standupContext()
                let unsupported = ClaimCheck.unsupported(in: result.text, sources: allowed)
                guard !unsupported.isEmpty else { return nil }
                self.debugLogReliability("unverified specifics in reply: \(unsupported.joined(separator: ", ")) — asking the same run to verify or drop them", groupName: groupName)
                return "Your reply stated specifics that appear in NONE of your tool output or the chat: "
                    + unsupported.joined(separator: ", ") + ". Verify each with a tool now, or leave it out, then call finish_task "
                    + "with the corrected reply. Never state unverified versions, paths, addresses or numbers."
            },
            imageGroupName: groupName
        )
        // Last resort: lines that still state unverified specifics are removed rather than posted as fact.
        if Reliability.isOn(.replyChecks), !outcome.failed, outcome.text != "[[silent]]", !outcome.text.hasPrefix("(stopped early") {
            let allowed = lastTurnObservations + "\n" + transcriptSoFar + "\n" + extraSuffix + "\n" + standupContext()
            let still = ClaimCheck.unsupported(in: outcome.text, sources: allowed)
            if !still.isEmpty {
                let cleaned = ClaimCheck.removingLines(stating: still, from: outcome.text)
                if !cleaned.isEmpty { outcome = IsolatedResult(text: cleaned, failed: false, tainted: outcome.tainted) }
            }
        }
        // Stopped early (budget, loop, guardrail freeze): say honestly what was verified instead of a bare error.
        if Reliability.isOn(.taskFocus), !outcome.failed, outcome.text.hasPrefix("(stopped early") {
            let reason = outcome.text.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            logStop(reason, context: "group: \(groupName)")
            let update = await stopUpdate(reason: reason, evidence: lastTurnObservations, transcript: String(transcriptSoFar.suffix(2_500)),
                                          audience: "the group \"\(groupName)\" (members: \(otherMembers.joined(separator: ", ")))",
                                          includeMemory: !untrustedInput)
            outcome = IsolatedResult(text: update, failed: false, tainted: outcome.tainted)
        }
        // The model server being down is an infrastructure problem, never something to post as the bot's reply.
        if !outcome.failed, outcome.text.hasPrefix(ModelConnection.unreachablePrefix) {
            outcome = IsolatedResult(text: "the model server (Ollama) isn't reachable", failed: true, tainted: outcome.tainted)
        }
        // Infrastructure failures ("no sandbox", "cancelled", "no response")
        // are never posted as if the bot had said them.
        if outcome.failed {
            lastTurnFailure = outcome.text
            if DebugSettings.shared.isEnabled {
                DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .error, context: "group: \(groupName)", text: "turn failed: \(outcome.text)")
            }
            return nil
        }
        let reply = outcome.text
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerant on purpose: a model that wraps the sentinel in a little
        // extra narration ("I'll stay quiet. [[silent]]") still means to
        // opt out, and letting the wrapper leak through as a real bubble
        // would defeat the entire point of the rule. Only exact silence
        // (or a genuinely empty reply) counts when NOT mentioned — being
        // mentioned always posts, even if the model echoes the token by
        // mistake, so a direct question never silently vanishes.
        guard !mustReply else { return (trimmed.isEmpty || trimmed == "[[silent]]") ? nil : reply }
        return (trimmed.isEmpty || trimmed.contains("[[silent]]")) ? nil : reply
    }

    /// A routine (set up in this bot's own 1:1 chat) firing into a group
    /// instead of its own chat — see `Routine.targetGroupID`/
    /// `GroupChatSession.fireRoutine`. Unlike `respondInGroup`, there's no
    /// `[[silent]]` opt-out: a routine is a directed instruction ("do X
    /// now"), not a passive per-turn "chime in if relevant" decision, so
    /// this always posts something unless the reply is genuinely empty.
    func fireRoutineInGroup(instruction: String, groupName: String, otherMembers: [String], transcriptSoFar: String) async -> String? {
        let suffix = "A routine you set up earlier just fired, instructing you to act in the group chat "
            + "\"\(groupName)\" (alongside: \(otherMembers.joined(separator: ", "))) rather than in your own "
            + "chat with your user. Do the instruction below and post the result to the group now — this is "
            + "a directed action you scheduled yourself, not a passive turn, so don't skip or stay silent."
        let goal = "Your scheduled instruction: \(instruction)"
            + (transcriptSoFar.isEmpty ? "" : "\n\n---\n\nRecent conversation in the group, for context:\n\(transcriptSoFar)")
        let outcome = await runIsolatedTaskResult(systemPromptSuffix: suffix, goal: goal, debugContext: "routine → group: \(groupName)",
                                                  allowBotMessaging: true)
        if outcome.failed { return nil }
        let reply = outcome.text
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // `finish_task`'s `outcome: "silent"` isn't actually restricted
        // to `respondInGroup`'s context — a confused model could still
        // call it here despite the suffix above explicitly saying not
        // to skip or stay silent, and `runIsolatedTask` would faithfully
        // return the literal `[[silent]]` sentinel for it. Unlike
        // `respondInGroup`, this has no real silence concept (a routine
        // is a directed action, always posted) — but posting that raw
        // sentinel text into the group as if it were the bot's actual
        // reply would be worse than just not posting anything.
        return (trimmed.isEmpty || trimmed == "[[silent]]") ? nil : reply
    }

    /// The shared mechanism behind both of the above: a fresh, one-shot
    /// `AgentRuntime` using THIS bot's own system prompt/skills/model/
    /// sandbox, seeded with no history — whatever `goal` is passed in is
    /// the whole context, not mixed with this bot's own ongoing user
    /// conversation — and no `list_bots`/`message_bot` of its own, so
    /// neither a delegation nor a group turn can recurse into a chain.
    ///
    /// Waits its turn behind whatever else is currently running for this
    /// bot (its own chat, another delegation, another group turn) before
    /// claiming the run lock — see `isBusy`'s doc comment. Ordering among
    /// waiters is FIFO.
    ///
    /// Throws `CancellationError` if the calling `Task` is cancelled
    /// while still queued (e.g. `Bot.stop()` on a chat that hasn't
    /// reached the front yet) — every caller MUST treat that as "never
    /// acquired" and skip whatever it was about to protect with a
    /// matching `releaseRunLock()`, not just log the error and continue.
    /// Without this, a cancelled waiter used to sit on a plain
    /// `withCheckedContinuation` forever: that API doesn't observe
    /// cancellation on its own, and nothing else was ever going to wake
    /// it back up, so it would silently outlive the `Task.cancel()` that
    /// was supposed to stop it, then eventually run anyway once its
    /// turn came up.
    private func acquireRunLock() async throws {
        guard isBusy else {
            isBusy = true
            return
        }
        try Task.checkCancellation()
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                runLockWaiters.append(RunLockWaiter(id: waiterID, continuation: continuation))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelRunLockWaiter(waiterID) }
        }
        guard acquired else {
            throw CancellationError()
        }
    }

    /// Hands the lock to the next waiter (if any — `isBusy` stays true,
    /// ownership just transfers) or releases it entirely.
    private func releaseRunLock() {
        if !runLockWaiters.isEmpty {
            runLockWaiters.removeFirst().continuation.resume(returning: true)
        } else {
            isBusy = false
        }
    }

    /// Removes and resumes one specific waiter, if it's still queued —
    /// a no-op if `releaseRunLock` already dequeued it first. Both of
    /// those are the only two places that ever resume a waiter, both
    /// are MainActor-isolated (this bot's whole class is), and both
    /// gate on "is this waiter still in `runLockWaiters`" before acting
    /// — so exactly one of them ever wins for a given waiter, never
    /// both and never neither. Resumes with `false`, not `true`: see
    /// `acquireRunLock`'s doc comment for why that distinction is load-
    /// bearing, not cosmetic.
    private func cancelRunLockWaiter(_ waiterID: UUID) {
        guard let index = runLockWaiters.firstIndex(where: { $0.id == waiterID }) else { return }
        runLockWaiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Reuses `pendingApproval` — the same card the user already sees for
    /// this bot's normal conversation. Safe from the two-runs-at-once
    /// overwrite risk that used to exist here: `acquireRunLock`/
    /// `releaseRunLock` guarantee only one run (this one, the normal chat,
    /// or another delegation/group turn) ever holds the bot's sandbox — and
    /// so ever owns `pendingApproval` — at a time.
    ///
    /// Runs as its own independent, unstructured `Task` rather than a
    /// plain nested `await` — deliberately NOT inheriting cancellation
    /// from whoever's awaiting this. `handleDelegatedTask`'s caller is
    /// another bot's own `drainQueue`, and `Bot.stop()` cancels only that
    /// bot's `drainTask`; without this, cancelling THAT task would
    /// cascade down through the nested `await` chain into THIS bot's
    /// work too, stopping a completely different bot's sandbox because
    /// someone hit "Stop" on their own chat. Same reasoning for a group
    /// turn (`GroupChatSession.runWorker`'s own `Task`, unrelated to any
    /// member's `drainTask`).
    /// Appended to every isolated run's prompt. Without it, models narrate
    /// their intent as plain text ("I'll post it now") and the posted
    /// message ends up being that narration instead of the actual content.
    private static let isolatedReplyContract = """
        How your reply is delivered: the `summary` you pass to finish_task is posted verbatim as your \
        message — it is what everyone reads. Put the complete, final message there (for a stand-up, \
        announcement, or answer: the full text itself, not a description of it). Do NOT write plain text \
        first announcing what you're about to post or confirming you did; just do any needed work with \
        tools, then call finish_task with the finished message. When you call a tool, call it FIRST — do not \
        write a paragraph and then repeat the same paragraph alongside the call.

        Your user mostly reads your private 1:1 chat, not this one. When something meaningful happens \
        here (a task done, a result, a blocker, a decision needed), also call update_user with a short \
        note so they're kept informed — load the where-to-post skill if unsure what belongs where.
        """

    /// `failed` marks text that is an infrastructure message ("no sandbox",
    /// "cancelled", "didn't produce a response"), not something the bot said —
    /// group turns and routines must never post it as if the bot wrote it.
    struct IsolatedResult {
        let text: String
        let failed: Bool
        /// The run read untrusted content, so the asker must not memorize or trust the reply.
        var tainted = false
    }

    /// `followUp` sees each result while the run (and this bot's run lock) is
    /// still held. Returning a correction sends it into the SAME runtime, so
    /// the bot keeps everything its tools already returned and only has to fix
    /// its answer, instead of a fresh run repeating all of that work. At most
    /// `maxFollowUps` rounds.
    static let maxFollowUps = 2

    private func runIsolatedTaskResult(
        systemPromptSuffix: String, goal: String, debugContext: String,
        goalHandler: (@Sendable (String, [String: AnyCodable], Int) async -> [String: Any])? = nil,
        untrustedInput: Bool = false,
        plainReplyEndsTurn: Bool = false,
        allowBotMessaging: Bool = false,
        initialTaint: [TaintSource] = [],
        withheldTools: [String] = [],
        onDraft: (@MainActor (String?) -> Void)? = nil,
        followUp: (@MainActor (IsolatedResult) async -> String?)? = nil,
        imageGroupName: String? = nil
    ) async -> IsolatedResult {
        guard let sandbox, let handle else {
            return IsolatedResult(text: "\(name) has no running sandbox to work with right now.", failed: true)
        }
        // Unstructured on purpose (the run must outlive neither cancel nor
        // caller confusion), but cancellation is forwarded explicitly below.
        let inner = Task<IsolatedResult, Never> {
            let queuedSpan = BotActivity.shared.begin(bot: self, kind: .queued, detail: debugContext)
            do {
                try await acquireRunLock()
            } catch {
                BotActivity.shared.end(queuedSpan)
                // Cancelled while still queued — genuinely never
                // acquired the lock, so `releaseRunLock()` below must
                // NOT run for this call (see `acquireRunLock`'s doc
                // comment); returning here, before the `defer` is even
                // registered, is what guarantees that.
                return IsolatedResult(text: "\(name)'s task was cancelled before its turn came up.", failed: true)
            }
            BotActivity.shared.end(queuedSpan)
            let runSpan = BotActivity.shared.begin(bot: self, kind: .running, detail: debugContext)
            currentRunLockOwner = .isolated(debugContext)
            defer {
                BotActivity.shared.end(runSpan)
                currentRunLockOwner = nil
                releaseRunLock()
            }
            let model = selectedModel
            let budgets = AgentRuntime.Budgets(
                maxIterations: Self.isUnlimited(maxIterationsText) ? 40 : Self.parsedLimit(maxIterationsText, default: 40, range: 1...1_000),
                maxTokens: Self.parsedLimit(maxTokensText, default: 200_000, range: 1_000...50_000_000)
            )
            let selectedSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }

            // Which text gets posted is decided by `IsolatedReplyPicker` (see
            // its doc comment) — neither the model's plain-text turns nor
            // `finish_task`'s summary is reliably the real answer, so
            // picking one field by position (last-wins either way) was
            // wrong in one direction or the other.
            var replyPicker = IsolatedReplyPicker()
            let toolCallCounter = ToolCallCounter()
            let lessonTrail = LessonTrail()
            let phaseTracker = PhaseTracker()
            let botIDForPhase = id
            // Set when `finish_task` is called with `outcome: "silent"` — the
            // reliable way to opt out of responding (see `respondInGroup`),
            // backed by the same required-tool-call schema as `finish_task`
            // itself rather than hoping the model reproduces an exact string
            // like `[[silent]]` verbatim with no narration wrapped around it.
            var isSilent = false
            // Live text for the UI while the model streams (see `onDraft`):
            // reset whenever a tool starts so it always shows the current step.
            var draftText = ""
            var lastDraftFlush = Date.distantPast
            func publishDraft(_ text: String?) {
                guard let onDraft else { return }
                Task { @MainActor in onDraft(text) }
            }
            let taintProbe = RuntimeProbe()
            // Asking another bot for information mid-task. Not from a delegated request (no chains), and not
            // with a friend's text in context. A busy recipient answers from what it already knows.
            let messagingAllowed = allowBotMessaging && !untrustedInput
            var listBotsForRun: (@Sendable () async -> [[String: Any]])?
            var messageBotForRun: (@Sendable (String, String) async -> [String: Any])?
            if messagingAllowed {
                listBotsForRun = { [weak self] in
                    await MainActor.run { self?.listOtherBots() ?? [] }
                }
                messageBotForRun = { [weak self] to, message in
                    guard let self else { return ["error": "bot no longer available"] }
                    let tainted = await taintProbe.runtime?.isTainted ?? false
                    return await self.delegateToBot(named: to, message: message, quickIfBusy: true, senderTainted: tainted)
                }
            }
            let runtime = AgentRuntime(
                model: await makeModelBackend(),
                sandbox: sandbox,
                sandboxID: handle.id,
                tools: ToolRegistry(
                    skills: selectedSkills,
                    // Untrusted turn (a friend's text is in context): nothing that
                    // writes durable state — memory, tasks, routines — is offered,
                    // so injected text can't plant a persistent instruction.
                    onRemember: { [weak self] text in
                        await MainActor.run { self?.addMemory(text) ?? false }
                    },
                    onRecallMemory: { [weak self] query in
                        await self?.recallMemory(matching: query) ?? []
                    },
                    // Self-scoped, same as the memory tools right above
                    // — and this is exactly where "carry a task across
                    // contexts" actually matters: a group turn or
                    // delegation checking/completing its own tasks with
                    // no other way to see anything but the system
                    // prompt's stale-at-start-of-run snapshot.
                    onRememberTask: { [weak self] arguments in
                        await MainActor.run { self?.addTaskFromTool(arguments) ?? ["error": "bot no longer available"] }
                    },
                    onCompleteTask: { [weak self] arguments in
                        await MainActor.run { self?.completeTaskFromTool(arguments) ?? ["error": "bot no longer available"] }
                    },
                    onListTasks: { [weak self] in
                        await MainActor.run { self?.listTasksForTool() ?? [] }
                    },
                    // Self-scoped, unlike list_bots/message_bot/create_bot/
                    // add_bot_to_group (deliberately withheld from an
                    // isolated run, so it can't recurse) — creating a
                    // routine here only ever affects THIS bot's own
                    // schedule, no recursion or cross-bot side effect risk.
                    // Left out of this `ToolRegistry` entirely until now,
                    // which meant a group turn or delegation could check
                    // its own routines (`onListRoutines`) but not actually
                    // act on what it found — e.g. "check if X exists, if
                    // not create it" had no way to do the "create it" half.
                    onCreateRoutine: { [weak self] arguments in
                        await MainActor.run {
                            self?.createRoutineFromTool(arguments) ?? ["error": "bot no longer available"]
                        }
                    },
                    onEditRoutine: { [weak self] arguments in
                        await MainActor.run {
                            self?.editRoutineFromTool(arguments) ?? ["error": "bot no longer available"]
                        }
                    },
                    onRemoveRoutine: { [weak self] arguments in
                        await MainActor.run {
                            self?.removeRoutineFromTool(arguments) ?? ["error": "bot no longer available"]
                        }
                    },
                    // Read-only and self-scoped, same reasoning — no
                    // recursion or side-effect risk, and this is exactly
                    // where the need actually shows up: a group turn or
                    // delegation checking its own routines/settings with no
                    // other way to see anything but the system prompt's
                    // stale-at-start-of-run snapshot.
                    onListRoutines: { [weak self] in
                        await MainActor.run { self?.listRoutinesForTool() ?? [] }
                    },
                    onGetProfile: { [weak self] in
                        await MainActor.run { self?.getProfileForTool() ?? ["error": "bot no longer available"] }
                    },
                    onListBots: listBotsForRun,
                    onMessageBot: messageBotForRun,
                    // Self-scoped display-only note into this bot's own 1:1
                    // chat — the way an isolated run keeps the user informed.
                    onUpdateUser: { [weak self] message in
                        await MainActor.run {
                            self?.postUpdateToUser(message, source: debugContext) ?? ["error": "bot no longer available"]
                        }
                    },
                    onAskHelpers: { [weak self] tasks in
                        await self?.runHelpers(tasks) ?? ["error": "bot no longer available"]
                    },
                    onRequestCredentials: { [weak self] arguments in
                        let tainted = await taintProbe.runtime?.isTainted ?? false
                        return await self?.requestCredentialsFromTool(arguments, untrusted: untrustedInput || tainted)
                            ?? ["error": "bot no longer available"]
                    },
                    onGoalTool: goalHandler.map { handler in
                        { name, arguments in
                            var arguments = arguments
                            arguments["_observations"] = AnyCodable(toolCallCounter.observations)
                            return await handler(name, arguments, toolCallCounter.value)
                        }
                    },
                    onPostImage: imageGroupName.map { groupName in
                        { [weak self] caption, data in
                            await MainActor.run {
                                self?.postImageToGroup(groupName: groupName, caption: caption, data: data) ?? ["error": "bot no longer available"]
                            }
                        }
                    },
                    onBotInstructions: { [weak self] botName, mode, text in
                        let tainted = await taintProbe.runtime?.isTainted ?? false
                        return await MainActor.run {
                            self?.botInstructionsForTool(botName: botName, mode: mode, text: text, untrusted: untrustedInput || tainted)
                                ?? ["error": "bot no longer available"]
                        }
                    }
                ),
                permissions: permissions,
                budgets: budgets,
                modelName: model,
                onEvent: { [weak self] event in
                    switch event {
                    case .message(let msg):
                        replyPicker.observe(msg)
                        phaseTracker.set(responding: false, botID: botIDForPhase)
                    case .toolCompleted(let toolName, let resultJSON):
                        toolCallCounter.noteOutput(toolName, resultJSON)
                        lessonTrail.completed(toolName, resultJSON: resultJSON)
                    case .toolStarted(let toolName, let argumentsJSON):
                        lessonTrail.started(toolName, argumentsJSON: argumentsJSON)
                        toolCallCounter.note(toolName)
                        toolCallCounter.noteOutput(toolName, argumentsJSON)
                        phaseTracker.set(responding: false, botID: botIDForPhase)
                        if !draftText.isEmpty { draftText = ""; publishDraft(nil) }
                    case .messageDelta(let delta):
                        phaseTracker.set(responding: true, botID: botIDForPhase)
                        draftText += delta
                        if Date().timeIntervalSince(lastDraftFlush) > 0.08 {
                            lastDraftFlush = Date()
                            // Not the model's thinking: tagged blocks are hidden, and so is a draft that has
                            // turned into the model talking itself round in circles.
                            let shown = ReasoningText.visible(draftText)
                            publishDraft(shown.isEmpty || ReasoningText.looksLikeDeliberation(shown) ? nil : shown)
                        }
                    case .status(.aborted("silent")):
                        isSilent = true
                    default:
                        break
                    }
                    Task { @MainActor in self?.logToDebugConsole(event, context: debugContext) }
                },
                requestApproval: { [weak self] approval in
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            // Never leave the continuation unresumed: a run that
                            // can't surface its card must not hang forever.
                            guard let self else { continuation.resume(returning: .deny); return }
                            self.pendingApproval = PendingApproval(
                                approval: approval, continuation: continuation,
                                owner: self.currentRunLockOwner ?? .isolated(debugContext)
                            )
                            // A group turn / delegation / routine has nobody
                            // necessarily watching. It holds this bot's run lock,
                            // so after 15 minutes without an answer it is denied
                            // and the bot is freed.
                            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                            if let pending = self.pendingApproval, pending.approval.id == approval.id {
                                self.pendingApproval = nil
                                pending.continuation.resume(returning: .deny)
                            }
                        }
                    }
                }
            ,
                alwaysRequireApproval: untrustedInput,
                actionReviewer: makeActionReviewer(),
                // A friend's text is in context: nothing that writes durable
                // state is offered, so injected text can't plant a lasting
                // instruction (memory, tasks, routines).
                excludedTools: Set(untrustedInput
                    ? ["remember", "remember_task", "create_routine", "edit_routine", "remove_routine"]
                    : []).union(withheldTools),
                audit: AuditLog.shared,
                inbox: PendingInboxStore.standard,
                initialTaint: initialTaint,
                plainReplyEndsTurn: plainReplyEndsTurn,
                // Goal work must still record its steps, so only without a goal.
                answerEndsTurnAfterTools: goalHandler == nil,
                seenResults: seenResults
            )

            taintProbe.runtime = runtime
            let runGoal = await withRelevantMemoryContext(goal)
            let runPrompt = fullSystemPrompt(isolated: true) + "\n\n---\n\n" + systemPromptSuffix + "\n\n" + Self.isolatedReplyContract
            let telemetry = TelemetryContext(bot: name, purpose: debugContext)
            await Telemetry.$context.withValue(telemetry) { await runtime.start(systemPrompt: runPrompt, goal: runGoal) }
            @MainActor func currentResult() async -> IsolatedResult {
                let runTainted = await runtime.isTainted
                lastTurnObservations = toolCallCounter.observations
                lastTurnToolCalls = toolCallCounter.value
                let picked = replyPicker.result
                let resultText = picked ?? "(\(name) didn't produce a response.)"
                return IsolatedResult(text: isSilent ? "[[silent]]" : resultText, failed: picked == nil && !isSilent, tainted: runTainted)
            }
            var result = await currentResult()
            let reviewTainted = result.tainted || untrustedInput
            Task { @MainActor [weak self] in await self?.reviewRunForLesson(lessonTrail, task: runGoal, tainted: reviewTainted) }
            var rounds = 0
            while rounds < Self.maxFollowUps, !Task.isCancelled, let correction = await followUp?(result) {
                rounds += 1
                replyPicker = IsolatedReplyPicker()
                isSilent = false
                draftText = ""
                publishDraft(nil)
                await Telemetry.$context.withValue(telemetry) { await runtime.send(correction) }
                let next = await currentResult()
                // Keep the first answer if the follow-up produced nothing usable.
                if next.failed { break }
                result = next
            }
            return result
        }
        return await withTaskCancellationHandler { await inner.value } onCancel: { inner.cancel() }
    }

    // MARK: - Boot

    func boot() async {
        status = "Waiting for SSH tunnel…"
        guard await waitForTunnel() else {
            status = "sandbox-manager is unreachable at \(managerBaseURL) after 10s. "
                + "Check Console.app for [ssh tunnel] logs from this app."
            return
        }

        let secrets = try? await SecretStore().resolveForExecution(names: [managerTokenName])
        guard let token = secrets?[managerTokenName] else {
            status = "No \(managerTokenName) in Keychain. See ContentView.swift's comment for how to add it."
            return
        }

        if RemoteSandboxManager.sharedToken.value == nil { RemoteSandboxManager.sharedToken.value = token }
        let provider = RemoteSandboxManager(baseURL: managerBaseURL, token: token)
        sandbox = provider
        state = .booting(id)
        status = "Booting sandbox…"
        do {
            // Each bot is its own persistent container — task_id IS the
            // bot's id, so re-launching the app re-attaches to the same
            // container (and its state) rather than creating a new one.
            let created = try await provider.create(taskID: id, persistent: true)
            handle = created
            Task { await self.configureVMBasics(sandbox: provider, sandboxID: created.id) }
            if let vncString = created.metadata["vnc_url"], let vncURL = URL(string: vncString) {
                state = .running(vncURL: vncURL)
            } else {
                state = .failed("Sandbox booted but returned no vnc_url")
            }
        } catch {
            state = .failed(error.localizedDescription)
            status = error.localizedDescription
            return
        }

        // A `.remote` bot still needs the sandbox above (run_shell/GUI
        // tools run there regardless of where the model itself lives) but
        // has no local Ollama to wait for, and no reliable `/v1/models`
        // list across every OpenAI-compatible server — its model id is
        // just typed in directly (see `BotSettingsTab`).
        guard modelProvider == .ollama else {
            status = "Ready"
            await refreshPermissions()
            return
        }
        status = "Waiting for Ollama…"
        guard await waitForOllama() else {
            status = "ollama serve is unreachable on 127.0.0.1:11434 after 10s. "
                + "Check Console.app for [ollama] logs from this app."
            return
        }
        if let models = try? await OllamaBackend().availableModels(), !models.isEmpty {
            availableModels = models.sorted()
            if !models.contains(selectedModel) { selectedModel = models[0] }
        } else {
            status = "Ollama is running but has no models pulled — `ollama pull \(selectedModel)` first."
            return
        }
        status = "Ready"
        await refreshPermissions()
    }

    /// The local model list, for a bot whose main model is remote (boot only loads it for local ones): the
    /// fallback model picker needs it.
    func loadLocalModelsIfNeeded() async {
        guard availableModels.isEmpty, let models = try? await OllamaBackend().availableModels(), !models.isEmpty else { return }
        availableModels = models.sorted()
    }

    /// The tunnel is a child process started on app launch (`AppDelegate`);
    /// SSH's own handshake plus first connect takes a moment, so booting
    /// right after launch can easily beat it. Poll rather than fail once.
    private func waitForTunnel(attempts: Int = 20, delay: Duration = .milliseconds(500)) async -> Bool {
        let healthzURL = managerBaseURL.appendingPathComponent("healthz")
        for _ in 0..<attempts {
            if let (_, response) = try? await URLSession.shared.data(from: healthzURL),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
            try? await Task.sleep(for: delay)
        }
        return false
    }

    /// `ollama serve` is also a child process started on app launch
    /// (`OllamaManager`), same timing caveat as `waitForTunnel`.
    private func waitForOllama(attempts: Int = 20, delay: Duration = .milliseconds(500)) async -> Bool {
        for _ in 0..<attempts {
            if isLocalPortOpen(port: 11434) { return true }
            try? await Task.sleep(for: delay)
        }
        return false
    }

    // MARK: - Permissions

    func refreshPermissions() async {
        sessionAllowedBinaries = await permissions.list(scope: .session)
        globalAllowedBinaries = await permissions.list(scope: .global)
        blanketShellScopes = await permissions.blanketScopes(botID: id)
    }

    func revokeAllShell(scope: RunShellPermissions.BlanketScope) async {
        await permissions.revokeAll(botID: id, scope: scope)
        await refreshPermissions()
    }

    func revokePermission(_ binary: String, scope: RunShellPermissions.Scope) async {
        await permissions.revoke(binary, scope: scope)
        await refreshPermissions()
    }

    /// The system prompt actually sent to the model: the editable text plus
    /// a name+description INDEX of selected skills — not their full
    /// content, which would resend on every loop iteration whether or not
    /// it was ever relevant. `ToolRegistry(skills:)` is what actually loads
    /// a skill's full text, lazily, via the `use_skill` tool, the moment
    /// (if ever) the model calls it.
    /// `isolated: true` is for group turns, delegations, and routines-in-
    /// group (`runIsolatedTask`): they run with no `list_bots`/`message_bot`,
    /// so the other-bots directory (and its instructions to use those
    /// tools) is both dead weight and actively misleading there, and the
    /// skills catalog is trimmed to short one-liners. Together that's
    /// roughly 1.5-2k fewer prompt tokens to process on EVERY member's
    /// turn — which adds up fast on a local model.
    private func fullSystemPrompt(isolated: Bool = false) -> String {
        // Stated plainly up front rather than left for the model to infer
        // (or guess wrong) — needed for e.g. `add_bot_to_group` when the
        // user asks a bot to add ITSELF to a group by name, and for a
        // group turn where the transcript is labeled by name and the bot
        // needs to recognize its own lines versus others'.
        var result = "Your name is \(name)."
        if !tagline.isEmpty {
            result += " Your role: \(tagline)."
        }
        result += "\n\n" + BuiltInSystemPrompt.text
        result += "\n\nYour machine: you work in your own private Linux VM" + (handle.map { " (hostname shellhouse-vm-\($0.id))" } ?? "")
            + ". Every other bot has its own separate VM — nothing you install, download or save here appears on theirs, "
            + "and you cannot see theirs. Never describe it as a shared sandbox. If something is needed on every member's "
            + "machine, each member does it on their own VM; to share a result or file contents, post it in the chat."
        let custom = systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            result += "\n\n---\n\nAdditional instructions from the user for this bot (in addition to everything above):\n\n" + custom
        }
        let selected = availableSkills.filter { selectedSkillIDs.contains($0.id) }
        if !selected.isEmpty {
            if isolated {
                // Group turns/delegations/routines: names only. The one-line
                // descriptions were ~1.5k tokens re-processed on EVERY member's
                // turn — and with several bots sharing one local model, that
                // prompt processing (not generation) is what makes them take
                // turns instead of running side by side.
                let alreadyInThisPrompt: Set<String> = ["goal-driven-work"]
                let loadable = selected.map(\.id).filter { !alreadyInThisPrompt.contains($0) }
                result += "\n\n---\n\nPlaybooks you can load with use_skill(name) when one clearly fits what you're doing: "
                    + loadable.joined(separator: ", ") + ". The rules for group chats and shared goals are already in this prompt; do not load those playbooks."
            } else {
                result += "\n\n---\n\nSkills available via the use_skill tool. Each is a playbook for a specific "
                    + "task — call use_skill(name: \"<name>\") to load one's full instructions ONLY when its "
                    + "description actually matches what you're about to do:\n\n"
                for skill in selected {
                    result += "- \(skill.id): \(skill.description.isEmpty ? skill.name : skill.description)\n"
                }
            }
        }
        if !memoryBook.entries.isEmpty {
            let core = memoryBook.core(limit: Self.coreMemoryLimit)
            result += "\n\n---\n\nYour most important notes from earlier conversations — follow "
                + "these unless the current conversation says otherwise:\n\n"
            for memory in core {
                result += "- \(memory.text)\n"
            }
            let more = memoryBook.entries.count - core.count
            if more > 0 {
                result += "\n(\(more) more notes are stored. The ones relevant to each message are shown with it; "
                    + "search the rest with recall_memory.)\n"
            }
        }
        if !tasks.isEmpty {
            result += "\n\n---\n\nOne-shot tasks you're currently carrying (see remember_task/complete_task) "
                + "— these follow you into a group turn or a delegation, which otherwise have no access to "
                + "your own conversation history, so this is how you stay aware of them there too. Call "
                + "complete_task the moment one is actually done — don't leave finished tasks sitting here:\n\n"
            for task in tasks {
                result += "- \(task.text)\n"
            }
        }
        if !routines.isEmpty {
            result += "\n\n---\n\nRoutines you've scheduled for yourself (see create_routine) — listed so you "
                + "know these exist and don't recreate a duplicate:\n\n"
            for routine in routines {
                result += "- \(routine.schedule.summary): \(routine.instruction)\n"
            }
        }
        let others = botDirectory.directory(excluding: id)
        if isolated, !others.isEmpty {
            // Group turns and routines: who to ask when the work needs something another bot has.
            result += "\n\n---\n\nOther bots, and what each one handles. When your task needs information another "
                + "bot has (its findings, files, results or decisions), ask it with message_bot instead of guessing or "
                + "asking your user; if message_bot isn't available in this run, @mention the bot in the group. Write a "
                + "self-contained question (it can't see your context) and use its answer in your reply:\n\n"
            for other in others {
                result += "- \(other.name): \(other.role)\n"
            }
        } else if !others.isEmpty {
            result += "\n\n---\n\nOther bots on this Mac, and what each one handles — use list_bots for a "
                + "live check (this list was current when this conversation started, but bots can be added, "
                + "removed, or renamed since). When the user @mentions one of them asking you to coordinate, "
                + "or when something is outside your own scope and one of these matches, use message_bot to "
                + "actually talk to them privately — the user sees only a \"Messaged <name>…\" notice in this "
                + "chat unless they click it, and you're the one who answers them here once you have a reply. "
                + "Once you learn which bot handles something, use the remember tool to note it so you don't "
                + "have to re-check next time. If nothing here actually matches, handle it yourself:\n\n"
            for other in others {
                result += "- \(other.name): \(other.role)\n"
            }
        }
        // Last on purpose: it changes every minute, and everything before it can
        // then be reused from the model server's prompt cache between runs.
        result += "\n\n" + TemporalContext.promptLine()
        return result
    }

    // MARK: - Chat

    /// Called from the Send button / Return key. Never blocks on the agent:
    /// the message shows in the transcript and the queue immediately, and
    /// `drainQueue` is what actually feeds messages to the runtime one at a
    /// time — letting you stage several messages while the agent is still
    /// working through an earlier one, the way a normal chat app does,
    /// instead of the input being locked until it finishes.
    func submitInput() {
        guard sandbox != nil, !input.isEmpty || !pendingAttachments.isEmpty else { return }
        let text = input
        let attachments = pendingAttachments
        input = ""
        pendingAttachments = []
        Task { await sendWithAttachments(text: text, attachments: attachments) }
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls {
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            pendingAttachments.append(PendingAttachment(url: url, isImage: isImage))
        }
    }

    func removeAttachment(_ attachment: PendingAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Turns picked files into what a message actually needs: an image
    /// becomes a base64 vision attachment (the same channel `screenshot`
    /// tool results use); anything else gets written into the sandbox's
    /// `/workspace` so the agent can open it by path, with a note in the
    /// message text pointing at where it landed — there's no way to hand a
    /// text model arbitrary file bytes directly, so "put it somewhere the
    /// agent can read it and say where" is the only real option for a
    /// non-image file.
    /// A leading `/<skill-id>` in the message — the manual counterpart to
    /// the model's own `use_skill` tool call, for the moment you already
    /// know exactly which playbook you want rather than trusting the model
    /// to pick it. Matches against ALL of `availableSkills`, not just the
    /// ones currently toggled on for this bot: explicitly typing the
    /// command is opting into it regardless of the checkbox state.
    func matchSlashCommand(in text: String) -> (skill: Skill, remainder: String)? {
        guard text.hasPrefix("/") else { return nil }
        let afterSlash = text.dropFirst()
        let parts = afterSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let token = parts.first, !token.isEmpty,
              let skill = availableSkills.first(where: { $0.id.caseInsensitiveCompare(token) == .orderedSame }) else {
            return nil
        }
        let remainder = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (skill, remainder)
    }

    /// Expands a matched `/<skill-id>` into the skill's full content —
    /// shown in the transcript and sent to the model exactly the same way
    /// (unlike `use_skill`'s tool-call/tool-result split), so what you see
    /// in the chat is genuinely what the model received, no hidden step.
    private func expandSlashCommand(_ text: String) -> String {
        guard let match = matchSlashCommand(in: text) else { return text }
        SlashCommandUsage.recordUse(match.skill.id)
        let instruction = match.remainder.isEmpty
            ? "Follow the skill's instructions above."
            : match.remainder
        return "Use the \"\(match.skill.name)\" skill:\n\n\(match.skill.content)\n\n---\n\n\(instruction)"
    }

    private func sendWithAttachments(text: String, attachments: [PendingAttachment]) async {
        guard let sandbox, let handle else { return }
        let text = expandSlashCommand(text)
        if DebugSettings.shared.isEnabled {
            let files = attachments.isEmpty ? "" : "  [+\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")]"
            DebugLog.shared.log(bot: "You", colorHex: "#0A84FF", kind: .user, context: "chat: \(name)", text: text + files)
        }
        var images: [String] = []
        var notes: [String] = []
        var names: [String] = []

        for attachment in attachments {
            let filename = attachment.url.lastPathComponent
            names.append(filename)
            guard let data = try? Data(contentsOf: attachment.url) else {
                notes.append("[Could not read attached file: \(filename)]")
                continue
            }
            if attachment.isImage {
                images.append(data.base64EncodedString())
            } else {
                do {
                    try await sandbox.writeFile(handle.id, path: "workspace/\(filename)", contents: data)
                    notes.append("[Attached file: workspace/\(filename)]")
                } catch {
                    notes.append("[Failed to attach file \(filename): \(error.localizedDescription)]")
                }
            }
        }

        var fullText = text
        if !notes.isEmpty {
            fullText = fullText.isEmpty ? notes.joined(separator: "\n") : fullText + "\n\n" + notes.joined(separator: "\n")
        }
        guard !fullText.isEmpty else { return }
        queueMessage(fullText, images: images, attachmentNames: names)
    }

    /// The shared path behind both `submitInput` (a real user message) and
    /// `fireRoutine` (a routine's scheduled message) — the whole point is
    /// that a routine's instruction lands exactly like a typed message,
    /// including showing up in the transcript, not a side channel the
    /// model or the UI treats differently.
    private func queueMessage(_ text: String, images: [String] = [], attachmentNames: [String] = []) {
        guard sandbox != nil else { return }
        displayMessages.append(DisplayMessage(role: .user, text: text, attachmentNames: attachmentNames))
        persistTranscript()
        messageQueue.append(QueuedMessage(text: text, images: images))
        guard !isDrainingQueue else { return }
        drainTask = Task { await drainQueue() }
    }

    /// Stops whatever this bot's own chat is currently doing — cancels
    /// the in-flight `Task`, which propagates into the model call (or a
    /// `run_shell` await) via cooperative cancellation, same mechanism
    /// `AgentRuntime.checkBudgets` checks between iterations. Also drops
    /// anything still queued behind it: continuing to auto-process a
    /// later message right after an explicit Stop would be surprising.
    /// Doesn't touch delegation/group-turn runs — those aren't this
    /// chat's own in-flight message.
    func stop() {
        drainTask?.cancel()
        drainTask = nil
        messageQueue.removeAll()
        // Otherwise a pending approval card from the chat being stopped
        // stays actionable — clicking Approve on it after Stop would let
        // one more action through despite everything else having just
        // been cancelled, and its continuation (a plain
        // `withCheckedContinuation`, which doesn't observe `Task`
        // cancellation on its own) would never resume at all if the
        // user never touches the card. Gated on `owner` — see
        // `RunLockOwner`'s doc comment — because `pendingApproval` is
        // one shared slot: if a delegation or group turn currently
        // holds the run lock and raised this SAME approval, it's not
        // this chat's to deny just because they're both surfaced
        // through the same UI slot right now.
        if let pending = pendingApproval, pending.owner == .ownChat {
            pendingApproval = nil
            pending.continuation.resume(returning: .deny)
        }
        answerCredentialRequest(nil)
    }

    // MARK: - Credentials

    /// The `request_credentials` tool: shows a form in this bot's 1:1 chat and waits. Secret values go
    /// to the Keychain; the model gets back only their names (and any non-secret values).
    func requestCredentialsFromTool(_ arguments: [String: AnyCodable], untrusted: Bool) async -> [String: Any] {
        let request: CredentialRequest
        let isLogin = (arguments["_kind"]?.value as? String) == "login"
        switch isLogin ? CredentialRequest.parseLogin(arguments) : CredentialRequest.parse(arguments) {
        case .success(let parsed): request = parsed
        case .failure(let error): return ["error": error.message]
        }
        if let reserved = request.fields.first(where: { SecretStore.isAppInternal($0.name) }) {
            return ["error": "'\(reserved.name)' is one of the app's own credentials; pick a different name for this field."]
        }
        guard pendingCredentialRequest == nil else {
            return ["error": "another credentials request is already waiting for your user; wait for it to be answered"]
        }
        let store = SecretStore()
        let savedNames = Set(((try? await store.list()) ?? []).map(\.name))
        // Everything asked for is a secret that is already saved: don't bother the user, point at the saved one.
        if !isLogin, request.fields.allSatisfy({ $0.secret && savedNames.contains($0.name) }) {
            let names = request.fields.map(\.name)
            return ["already_saved": names,
                    "note": "\(names.joined(separator: ", ")) is already saved, so there is nothing to ask your user. Use it: run_shell(use_secrets: "
                        + "[\(names.map { "\"\($0)\"" }.joined(separator: ", "))]) and read it as $\(names[0]). If it was rejected (expired or wrong), say so to your user instead of asking again."]
        }
        let answer: [String: String]? = await withCheckedContinuation { continuation in
            let pending = PendingCredentialRequest(request: request, savedNames: savedNames, untrusted: untrusted, continuation: continuation)
            pendingCredentialRequest = pending
            // Nobody may be watching (a group turn or routine): give up after 15 minutes, like approvals.
            let pendingID = pending.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                if self?.pendingCredentialRequest?.id == pendingID { self?.answerCredentialRequest(nil) }
            }
        }
        guard let answer else {
            return ["cancelled": true, "note": "Your user declined or didn't answer. Don't ask again for the same thing; tell them what you couldn't do without it."]
        }
        var saved: [String] = [], kept: [String] = [], missing: [String] = [], failed: [String] = []
        var plain: [String: String] = [:]
        for field in request.fields {
            let value = answer[field.name] ?? ""
            if !field.secret {
                if !value.isEmpty {
                    plain[field.name] = value
                    // A login's username is kept too, so the next sign-in can reuse it.
                    if isLogin { try? await store.put(name: field.name, value: value, notes: request.reason) }
                } else if isLogin, savedNames.contains(field.name), let saved = try? await store.resolveOne(name: field.name) {
                    plain[field.name] = saved
                } else {
                    missing.append(field.name)
                }
            } else if value.isEmpty {
                if savedNames.contains(field.name) { kept.append(field.name) } else { missing.append(field.name) }
            } else if (try? await store.put(name: field.name, value: value, notes: request.reason)) != nil {
                saved.append(field.name)
            } else {
                failed.append(field.name)
            }
        }
        return CredentialRequest.result(saved: saved, kept: kept, missing: missing, plain: plain, failed: failed)
    }

    /// Resolves the waiting credentials card: the typed values, or nil when declined (or the run stopped).
    func answerCredentialRequest(_ values: [String: String]?) {
        guard let pending = pendingCredentialRequest else { return }
        pendingCredentialRequest = nil
        pending.continuation.resume(returning: values)
    }

    /// Feeds queued messages to the runtime one at a time until the queue is
    /// empty. Guarded by `isDrainingQueue` (not `isBusy`) so a second call
    /// doesn't start a competing drain loop, while still starting a fresh
    /// one if a message arrives while `isBusy` is true for an unrelated
    /// reason (a delegation or group turn currently holds the run lock) —
    /// each iteration below waits its turn for that lock same as any other
    /// run would.
    private func drainQueue() async {
        guard !isDrainingQueue, let sandbox, let handle else { return }
        isDrainingQueue = true
        // A cancelled loop (Stop) must not pick up a message submitted right
        // after Stop: it would run inside the cancelled task and be cancelled
        // immediately. Leave it queued for the fresh drain started below.
        while !messageQueue.isEmpty && !Task.isCancelled {
            let queued = messageQueue.removeFirst()
            let queuedSpan = BotActivity.shared.begin(bot: self, kind: .queued, detail: "own chat")
            do {
                try await acquireRunLock()
                BotActivity.shared.end(queuedSpan)
            } catch {
                BotActivity.shared.end(queuedSpan)
                // Cancelled while queued (`stop()`) — never acquired the
                // lock, so no matching `releaseRunLock()` call follows;
                // stop the whole drain loop rather than just this one
                // message, since `stop()` clears `messageQueue` anyway.
                break
            }
            currentRunLockOwner = .ownChat
            let chatSpan = BotActivity.shared.begin(bot: self, kind: .running, detail: "own chat")
            // Belt-and-suspenders turn boundary: a genuinely new user
            // message should never land in a bubble left over from
            // however the previous turn ended (e.g. `Stop` cancelling
            // mid-stream, skipping the normal `.toolStarted`/task-summary
            // resets below).
            streamingIndex = nil
            // The model/provider/budgets can be changed between messages (the
            // settings only lock while the bot is working). A live runtime is
            // bound to the settings it was built with, so if they changed,
            // drop it: the branch below rebuilds one with the new settings and
            // reseeds it from this chat's history, so the conversation carries on.
            if runtime != nil, runtimeSettingsKey != currentRuntimeSettingsKey {
                runtime = nil
            }
            if let runtime {
                lastOwnChatToolOutput = ""
                let turnText = await withRelevantMemoryContext(queued.text)
                await Telemetry.$context.withValue(TelemetryContext(bot: name, purpose: "chat")) {
                    await runtime.send(turnText, images: queued.images)
                }
            } else {
                let model = selectedModel
                let budgets = AgentRuntime.Budgets(
                    maxIterations: Self.isUnlimited(maxIterationsText) ? 40 : Self.parsedLimit(maxIterationsText, default: 40, range: 1...1_000),
                    maxTokens: Self.parsedLimit(maxTokensText, default: 200_000, range: 1_000...50_000_000)
                )
                let selectedSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }
                let toolRegistry = ToolRegistry(
                        skills: selectedSkills,
                        onRemember: { [weak self] text in
                            await MainActor.run { self?.addMemory(text) ?? false }
                        },
                        onRecallMemory: { [weak self] query in
                            await self?.recallMemory(matching: query) ?? []
                        },
                        onRememberTask: { [weak self] arguments in
                            await MainActor.run { self?.addTaskFromTool(arguments) ?? ["error": "bot no longer available"] }
                        },
                        onCompleteTask: { [weak self] arguments in
                            await MainActor.run { self?.completeTaskFromTool(arguments) ?? ["error": "bot no longer available"] }
                        },
                        onListTasks: { [weak self] in
                            await MainActor.run { self?.listTasksForTool() ?? [] }
                        },
                        onCreateRoutine: { [weak self] arguments in
                            await MainActor.run {
                                self?.createRoutineFromTool(arguments) ?? ["error": "bot no longer available"]
                            }
                        },
                        onEditRoutine: { [weak self] arguments in
                            await MainActor.run {
                                self?.editRoutineFromTool(arguments) ?? ["error": "bot no longer available"]
                            }
                        },
                        onRemoveRoutine: { [weak self] arguments in
                            await MainActor.run {
                                self?.removeRoutineFromTool(arguments) ?? ["error": "bot no longer available"]
                            }
                        },
                        onListRoutines: { [weak self] in
                            await MainActor.run { self?.listRoutinesForTool() ?? [] }
                        },
                        onGetProfile: { [weak self] in
                            await MainActor.run { self?.getProfileForTool() ?? ["error": "bot no longer available"] }
                        },
                        onListBots: { [weak self] in
                            await MainActor.run { self?.listOtherBots() ?? [] }
                        },
                        onMessageBot: { [weak self] to, message in
                            guard let self else { return ["error": "bot no longer available"] }
                            let tainted = await self.runtime?.isTainted ?? false
                            return await self.delegateToBot(named: to, message: message, senderTainted: tainted)
                        },
                        onCreateBot: { [weak self] name, tagline, systemPrompt in
                            guard let self else { return ["error": "bot no longer available"] }
                            return await self.createBot(named: name, tagline: tagline, systemPrompt: systemPrompt)
                        },
                        onAddBotToGroup: { [weak self] botName, groupName in
                            guard let self else { return ["error": "bot no longer available"] }
                            return await self.addBotToGroup(botName: botName, groupName: groupName)
                        },
                        onPostToGroup: { [weak self] groupName, message in
                            await MainActor.run {
                                self?.postToGroup(groupName: groupName, message: message) ?? ["error": "bot no longer available"]
                            }
                        },
                        onAskHelpers: { [weak self] tasks in
                            await self?.runHelpers(tasks) ?? ["error": "bot no longer available"]
                        },
                        onRequestCredentials: { [weak self] arguments in
                            guard let self else { return ["error": "bot no longer available"] }
                            let tainted = await self.runtime?.isTainted ?? false
                            return await self.requestCredentialsFromTool(arguments, untrusted: tainted)
                        },
                        onPostImage: { [weak self] caption, data in
                            await MainActor.run { self?.postImageToOwnChat(caption: caption, data: data) ?? ["error": "bot no longer available"] }
                        },
                        onBotInstructions: { [weak self] botName, mode, text in
                            guard let self else { return ["error": "bot no longer available"] }
                            let tainted = await self.runtime?.isTainted ?? false
                            return await MainActor.run {
                                self.botInstructionsForTool(botName: botName, mode: mode, text: text, untrusted: tainted)
                            }
                        }
                    )
                let eventHandler: @Sendable (AgentRuntime.Event) -> Void = { [weak self] event in
                    Task { @MainActor in self?.handleEvent(event) }
                }
                let approvalHandler: @Sendable (Approval) async -> AgentRuntime.ApprovalDecision = { [weak self] approval in
                    await withCheckedContinuation { continuation in
                        Task { @MainActor in
                            guard let self else { continuation.resume(returning: .deny); return }
                            self.pendingApproval = PendingApproval(
                                approval: approval, continuation: continuation,
                                owner: self.currentRunLockOwner ?? .ownChat
                            )
                        }
                    }
                }
                var chosen: (any AgentEngine)?
                if engine == .smolagents {
                    do {
                        chosen = try await makeSmolAgentsEngine(
                            tools: toolRegistry, sandbox: sandbox, sandboxID: handle.id, budgets: budgets, model: model,
                            onEvent: eventHandler, requestApproval: approvalHandler
                        )
                    } catch {
                        // Fail visibly, then carry on with the built-in engine (same guardrails).
                        displayMessages.append(DisplayMessage(
                            role: .assistant,
                            text: "(smolagents engine unavailable: \(error.localizedDescription) — using the built-in engine for this chat.)"
                        ))
                    }
                }
                let newRuntime: any AgentEngine
                if let chosen {
                    newRuntime = chosen
                } else {
                    newRuntime = AgentRuntime(
                        model: await makeModelBackend(interactive: true),
                        sandbox: sandbox,
                        sandboxID: handle.id,
                        tools: toolRegistry,
                        permissions: permissions,
                        budgets: budgets,
                        modelName: model,
                        onEvent: eventHandler,
                        requestApproval: approvalHandler,
                        actionReviewer: makeActionReviewer(),
                        audit: AuditLog.shared,
                        inbox: PendingInboxStore.standard,
                        answerEndsTurnAfterTools: true,
                        seenResults: seenResults
                    )
                }
                runtime = newRuntime
                runtimeSettingsKey = currentRuntimeSettingsKey
                hasStarted = true
                // `text` (the message about to be sent) is already the last
                // entry in `displayMessages` (appended by `submitInput`
                // above) — everything before it is prior history to restore,
                // whether that's a saved conversation from a previous
                // launch or empty because this bot has never talked before.
                // Either way this is the ONE path a fresh `AgentRuntime`
                // takes (see `seed`'s doc comment) rather than branching on
                // "is this actually a resume."
                //
                // If a cached `contextSummary` exists, resend THAT plus
                // whatever's newer than it, instead of the bot's entire
                // persisted transcript — for a long-running chat, resending
                // everything here would just get summarized right back down
                // to roughly this same digest on the very next turn, paying
                // for that round trip again on every relaunch. `min(...)`
                // guards a summary that's now stale relative to a shorter
                // transcript rather than indexing out of bounds.
                let history: [ChatMessage]
                if let cached = contextSummary, cached.coveredMessageCount > 0 {
                    let coveredCount = min(cached.coveredMessageCount, displayMessages.count)
                    let summaryMessage = ChatMessage(
                        role: .user,
                        content: "(Earlier conversation summarized to keep this within the model's "
                            + "context — nothing before this point is verbatim anymore:)\n\n\(cached.text)"
                    )
                    let recent = displayMessages[coveredCount...].dropLast().map { ChatMessage(role: $0.role, content: $0.text) }
                    history = [summaryMessage] + recent
                } else {
                    history = displayMessages.dropLast().map { ChatMessage(role: $0.role, content: $0.text) }
                }
                await newRuntime.seed(systemPrompt: fullSystemPrompt(), history: Array(history))
                await newRuntime.send(await withRelevantMemoryContext(queued.text), images: queued.images)
            }
            BotActivity.shared.end(chatSpan)
            currentRunLockOwner = nil
            releaseRunLock()
        }
        isDrainingQueue = false
        let wasCancelled = Task.isCancelled
        drainTask = nil
        if wasCancelled && !messageQueue.isEmpty {
            // Stop → quick resubmit: the new message was queued while this
            // (cancelled) loop was still unwinding. Start a clean one for it.
            drainTask = Task { await drainQueue() }
        }
    }

    /// Streamed tokens are buffered and applied to `displayMessages` at
    /// most every ~60ms — mutating an `@Observable` array per token
    /// re-rendered (and re-highlighted) the whole transcript hundreds of
    /// times a reply. Every non-delta event flushes first, so ordering
    /// against messages/tool events is unchanged.
    private var pendingDeltaBuffer = ""
    private var deltaFlushTask: Task<Void, Never>?

    private func flushPendingDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingDeltaBuffer.isEmpty else { return }
        let delta = pendingDeltaBuffer
        pendingDeltaBuffer = ""
        if let index = streamingIndex {
            if pendingReuseClear {
                displayMessages[index].text = ""
                pendingReuseClear = false
            }
            displayMessages[index].text = ReasoningText.visible(displayMessages[index].text + delta)
        } else {
            displayMessages.append(DisplayMessage(role: .assistant, text: ReasoningText.visible(delta)))
            streamingIndex = displayMessages.count - 1
        }
    }

    private func handleEvent(_ event: AgentRuntime.Event) {
        logToDebugConsole(event)
        switch event {
        case .messageDelta:
            BotActivity.shared.setPhase(botID: id, .responding)
        case .toolStarted, .toolCompleted, .status, .message:
            BotActivity.shared.setPhase(botID: id, .working)
        default:
            break
        }
        if case .messageDelta(let delta) = event {
            pendingDeltaBuffer += delta
            if deltaFlushTask == nil {
                deltaFlushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard !Task.isCancelled else { return }
                    self?.flushPendingDelta()
                }
            }
            return
        }
        flushPendingDelta()
        switch event {
        case .status(let runtimeStatus):
            switch runtimeStatus {
            case .completed, .failed, .aborted: finishOwnChatLessonTrail()
            default: break
            }
            // A model call that comes back with no tool call at all just
            // means "keep going" (see `AgentRuntime.loop`'s "You did not
            // call a tool" nudge) — left alone, that used to open a brand
            // new bubble every single retry, so a plain "Hi!" could pile
            // up several near-identical bubbles before the model finally
            // acted. `streamingIndex` now stays set across those retries
            // (only `.toolStarted`/a fresh user turn clear it — see
            // below); this just ARMS a lazy clear of the reused bubble's
            // stale text, applied in `.messageDelta`/`.message` the
            // moment this iteration actually produces something new —
            // NOT eagerly here, because if this iteration turns out to
            // produce nothing at all (e.g. a finish_task call with no
            // accompanying text), blanking now would leave a permanently
            // empty orphaned bubble with nothing left to ever refill it.
            if case .executing = runtimeStatus, streamingIndex != nil {
                pendingReuseClear = true
            }
            status = describe(runtimeStatus)
        case .messageDelta:
            break
        case .message(let message):
            guard message.role != .system, !message.content.isEmpty else { return }
            // A run that stopped early: tell the user in plain words what was seen and what's needed, instead
            // of posting the internal reason. The reason itself goes to the debug console and Telemetry.
            if message.role == .assistant, message.isTaskSummary, message.content.hasPrefix("(stopped early") {
                let reason = message.content.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                logStop(reason, context: "own chat")
                let evidence = (runtimeToolOutput() ?? "")
                let recent = displayMessages.suffix(8).map { "\($0.role == .user ? "User" : name): \($0.text.prefix(400))" }.joined(separator: "\n")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let update = await self.stopUpdate(reason: reason, evidence: evidence, transcript: recent, audience: "your user, in your private chat",
                                                       includeMemory: true)
                    self.displayMessages.append(DisplayMessage(role: .assistant, text: update, toolName: nil, isTaskSummary: false))
                    self.persistTranscript()
                    self.hasUnread = true
                }
                return
            }
            // `!message.isTaskSummary` matters here: finish_task's own
            // summary must always land in its own fresh bubble (so it
            // keeps its collapsed "Done — tap for summary" treatment —
            // see `TranscriptView`) rather than overwriting whatever
            // bubble a preceding no-tool-call retry left `streamingIndex`
            // pointing at.
            if message.role == .assistant, !message.isTaskSummary, let index = streamingIndex {
                // Unconditionally replaces (not appends), so this already
                // clears any stale reused text on its own — no need to
                // separately consult `pendingReuseClear` here.
                displayMessages[index].text = message.content
                pendingReuseClear = false
            } else {
                var collapsed = message.isTaskSummary
                if collapsed {
                    // Only tuck the summary away when it repeats a reply already shown this turn;
                    // a turn whose answer lives only in the summary must show it as the reply.
                    let lastUser = displayMessages.lastIndex { $0.role == .user } ?? -1
                    let shown = displayMessages.suffix(from: lastUser + 1)
                        .filter { $0.role == .assistant && !$0.isTaskSummary && $0.toolName == nil && $0.interBotPeerID == nil }
                        .map(\.text)
                    collapsed = SummaryDisplay.collapses(summary: message.content, shownThisTurn: Array(shown))
                }
                displayMessages.append(DisplayMessage(
                    role: message.role, text: message.content,
                    toolName: message.toolName, isTaskSummary: collapsed
                ))
            }
            persistTranscript()
            hasUnread = true
        case .toolStarted(let name, let argumentsJSON):
            ownChatLessonTrail.started(name, argumentsJSON: argumentsJSON)
            status = "Running \(name)\(Self.toolDetail(argumentsJSON))…"
            // A real action just happened — whatever text comes next is a
            // genuinely new thought reacting to it, not another attempt
            // at the same one, so it earns its own bubble instead of
            // reusing (and overwriting) the one before the tool call.
            streamingIndex = nil
        case .toolCompleted(let name, let resultJSON):
            ownChatLessonTrail.completed(name, resultJSON: resultJSON)
            status = "Finished \(name)"
            lastOwnChatToolOutput = String((lastOwnChatToolOutput + "\n" + name + ": " + resultJSON).suffix(8_000))
        case .approvalNeeded, .guardrailDecision, .contextTrimmed:
            break  // surfaced via the card / the debug console, not here
        case .contextCompacted(let summary):
            // Only this bot's own chat persists a cache — a delegation
            // or group turn's isolated runtime (`runIsolatedTask`) has
            // no `displayMessages` of its own to approximate a covered
            // count against, and doesn't wire this case at all (its
            // `onEvent` switch falls through to `default`).
            contextSummary = ContextSummary(text: summary, coveredMessageCount: displayMessages.count)
            ContextSummaryStore.save(id: id, contextSummary!)
        }
    }

    /// ": <what it's acting on>" for the 1:1 status line — the command, file,
    /// URL or query, clipped — so "Running run_shell…" says WHICH command.
    static func toolDetail(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["command", "path", "url", "query", "app", "text", "name"] {
            if let value = object[key] as? String, !value.isEmpty {
                let oneLine = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                return ": " + (oneLine.count > 70 ? String(oneLine.prefix(70)) + "…" : oneLine)
            }
        }
        return ""
    }

    private func describe(_ status: AgentRuntime.Status) -> String {
        switch status {
        case .idle: return "Idle"
        case .planning: return "Thinking…"
        case .executing(let iteration, let maxIterations): return "Working… (\(iteration)/\(maxIterations))"
        case .waitingForApproval: return "Waiting for your approval…"
        case .completed: return "Done"
        case .failed(let message): return "Failed: \(message)"
        case .aborted("silent"): return "Nothing to add"
        case .aborted(let message): return "Stopped: \(message)"
        }
    }

    /// Mirrors every runtime event into the global debug console
    /// (Settings > Debug) — regardless of which bot's chat is open, and
    /// regardless of whether this run is this bot's own chat, a group
    /// turn, or a delegation (called from `runIsolatedTask`'s `onEvent`
    /// too). The whole point is seeing what's actually happening
    /// underneath, including the parts (isolated group/delegation runs)
    /// that are otherwise a black box in the normal UI. A no-op unless
    /// debug mode is on, checked fresh on every event rather than
    /// cached, so toggling it mid-run starts/stops logging immediately.
    static func decisionLabel(_ outcome: String) -> String {
        [
            "approved": "you approved", "denied_by_user": "you denied", "blocked": "blocked",
            "yolo_auto": "ran (YOLO)", "yolo_vetted": "ran (YOLO, vetted by the fast model)", "reviewer_auto": "approved by the reviewer",
            "granted_binary": "ran (standing grant)", "granted_blanket": "ran (allow all shell)",
        ][outcome] ?? outcome
    }

    private func logToDebugConsole(_ event: AgentRuntime.Event, context: String? = nil) {
        guard DebugSettings.shared.isEnabled else { return }
        switch event {
        case .status(let runtimeStatus):
            let kind: DebugLogEntry.Kind
            switch runtimeStatus {
            case .aborted("silent"): kind = .status   // the bot chose not to reply; not a failure
            case .failed, .aborted: kind = .error
            default: kind = .status
            }
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: kind, context: context, text: describe(runtimeStatus))
        case .messageDelta(let delta):
            DebugLog.shared.logDelta(bot: name, colorHex: colorHex, context: context, delta: delta)
        case .message(let message):
            // Empty assistant turns (a tool call with no text) are noise, and tool results are already logged
            // once as "← tool: …" by `.toolCompleted`.
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.role != .tool else {
                if message.role == .assistant { DebugLog.shared.discardStreaming(bot: name, context: context) }
                return
            }
            var text = message.content
            if message.role == .assistant, !message.isTaskSummary, !text.isEmpty {
                let key = context ?? ""
                if lastLoggedAssistantText[key] == text {
                    text = "(same text again — the model skipped the tool call and was nudged) " + text
                }
                lastLoggedAssistantText[key] = message.content
            }
            DebugLog.shared.log(
                bot: name, colorHex: colorHex,
                kind: message.role == .tool ? .tool : .message,
                context: context,
                text: text
            )
        case .toolStarted(let toolName, let argumentsJSON):
            let args = argumentsJSON == "{}" ? "" : " \(argumentsJSON)"
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .tool, context: context, text: "→ \(toolName)\(args)")
        case .toolCompleted(let toolName, let resultJSON):
            if resultJSON.contains("held_for_review") { refreshPendingReview() }
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .tool, context: context, text: "← \(toolName): \(resultJSON)")
        case .approvalNeeded(let approval):
            let flags = [approval.strict ? "strict" : nil, approval.untrusted ? "untrusted run" : nil].compactMap { $0 }
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: context,
                                text: "approval prompt: \(approval.toolName)" + (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")
                                    + (approval.reasons.isEmpty ? "" : " — " + approval.reasons.prefix(4).joined(separator: "; "))
                                    + " · " + String(approval.argumentsSummary.prefix(240)))
        case .guardrailDecision(let tool, let outcome, let detail):
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: outcome.hasPrefix("blocked") || outcome.hasPrefix("denied") ? .error : .status,
                                context: context, text: "approval decision: \(tool) — \(Self.decisionLabel(outcome))" + (detail.isEmpty ? "" : " · \(detail)"))
        case .contextCompacted(let summary):
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: context, text: "context compacted — what the bot now remembers of the earlier conversation:\n\(summary)")
        case .contextTrimmed(let detail):
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: context, text: "context compacted: \(detail)")
        }
    }

    // MARK: - Export

    private func roleLabel(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool: return "Tool"
        case .system: return "System"
        }
    }

    /// Sidebar row preview text — the last thing said in either direction,
    /// trimmed short. `nil` before the first message.
    var lastMessagePreview: String? {
        displayMessages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func markRead() {
        hasUnread = false
    }

    func exportTranscriptText() -> String {
        displayMessages.map { "\(roleLabel($0.role)):\n\($0.text)" }.joined(separator: "\n\n")
    }
}

/// Counts real (non-bookkeeping) tool executions in one isolated run — the
/// evidence signal `GroupGoal.updateStep` uses to decide whether a "done"
/// claim came from a turn that actually did something.
final class ToolCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private static let bookkeeping: Set<String> = [
        "finish_task", "update_user", "get_goal", "propose_goal", "add_goal_step", "edit_goal_step",
        "update_goal_step", "propose_goal_complete", "use_skill", "get_profile", "list_routines",
    ]
    private var pool = ""
    func note(_ toolName: String) {
        guard !Self.bookkeeping.contains(toolName) else { return }
        lock.lock(); count += 1; lock.unlock()
    }
    /// What this run's tools actually returned (most recent ~12k characters): the world's output, the only
    /// thing a "done" claim can be checked against.
    /// File reads are capped so a few large ones can't push command results (what evidence usually quotes)
    /// out of the pool.
    func noteOutput(_ toolName: String, _ text: String) {
        guard !Self.bookkeeping.contains(toolName) else { return }
        let reads: Set<String> = ["read_file", "search_files", "find_files", "list_files", "use_skill"]
        let entry = reads.contains(toolName) ? String(text.prefix(1_500)) : String(text.suffix(8_000))
        lock.lock()
        pool += "\n" + entry
        if pool.count > 40_000 { pool = String(pool.suffix(40_000)) }
        lock.unlock()
    }
    var observations: String { lock.lock(); defer { lock.unlock() }; return pool }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Forwards working/responding flips from a background agent loop to the
/// main-actor `BotActivity`, only when the value actually changes (the loop
/// emits an event per streamed token).
final class PhaseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var responding = false
    func set(responding newValue: Bool, botID: String) {
        lock.lock()
        let changed = responding != newValue
        responding = newValue
        lock.unlock()
        guard changed else { return }
        Task { @MainActor in
            BotActivity.shared.setPhase(botID: botID, newValue ? .responding : .working)
        }
    }
}

// MARK: - Pending review (guardrail quarantine)

extension Bot {
    func refreshPendingReview() {
        pendingReview = PendingInboxStore.standard.load(botID: handle?.id ?? id)
    }

    /// Applies a held change the user has now approved, through the same code
    /// path the agent's own tool call would have used.
    func approvePending(_ item: PendingItem) {
        switch item.tool {
        case "remember":
            if let text = item.arguments["text"]?.asString { _ = addMemory(text) }
        case "create_routine":
            _ = createRoutineFromTool(item.arguments)
        case "edit_routine":
            _ = editRoutineFromTool(item.arguments)
        default:
            break   // nothing else is ever held
        }
        PendingInboxStore.standard.remove(botID: item.botID, id: item.id)
        refreshPendingReview()
    }

    func dismissPending(_ item: PendingItem) {
        PendingInboxStore.standard.remove(botID: item.botID, id: item.id)
        refreshPendingReview()
    }

    /// "Treat this chat as trusted again" — clears web/MCP/skill taint on the
    /// live runtime (friend-message taint stays).
    func clearUntrustedFlag() {
        guard let runtime else { return }
        Task { await runtime.clearTaint() }
    }
}

// MARK: - smolagents engine

extension Bot {
    enum SmolAgentsError: LocalizedError {
        case remoteProviderUnsupported
        var errorDescription: String? {
            "the pilot supports local Ollama models only (this bot uses a remote provider)"
        }
    }

    func makeSmolAgentsEngine(
        tools: ToolRegistry, sandbox: RemoteSandboxManager, sandboxID: String, budgets: AgentRuntime.Budgets, model: String,
        onEvent: @escaping @Sendable (AgentRuntime.Event) -> Void,
        requestApproval: @escaping @Sendable (Approval) async -> AgentRuntime.ApprovalDecision
    ) async throws -> any AgentEngine {
        guard modelProvider == .ollama else { throw SmolAgentsError.remoteProviderUnsupported }
        let service = SmolAgentsService.shared
        let settings = try await service.engineSettings()
        return SmolAgentsEngine(
            proxy: service.proxy, settings: settings, sandbox: sandbox, sandboxID: sandboxID, tools: tools,
            permissions: permissions, budgets: budgets, modelName: model, onEvent: onEvent,
            requestApproval: requestApproval, actionReviewer: makeActionReviewer(), audit: AuditLog.shared,
            inbox: PendingInboxStore.standard
        )
    }

    /// The fast-model approval reviewer (`ActionReviewPrompt`): settles routine approval asks so bots can
    /// work on their own. nil from the closure (model down, unparsable reply) means the user is asked.
    func makeActionReviewer() -> ActionReviewer {
        { [weak self] request in
            guard let self else { return nil }
            let botName = await MainActor.run { self.name }
            return await Telemetry.$context.withValue(TelemetryContext(bot: botName, purpose: "approval review")) {
                await self.review(request)
            }
        }
    }

    private func review(_ request: ActionReviewRequest) async -> ActionReview? {
        let (backend, model) = await reviewerBackend()
        let messages = [
            ChatMessage(role: .system, content: ActionReviewPrompt.systemPrompt(for: request)),
            ChatMessage(role: .user, content: ActionReviewPrompt.user(request)),
        ]
        let raw: String?
        if let ollama = backend as? OllamaBackend {
            raw = try? await ollama.chatStructured(messages: messages, model: model, schema: ActionReviewPrompt.schema)
        } else {
            raw = try? await backend.chat(messages: messages, tools: [], model: model, temperature: 0).message.content
        }
        let review = raw.flatMap(ActionReviewPrompt.parse)
        if DebugSettings.shared.isEnabled {
            let verdict = review.map { $0.approve ? "auto-approved" : "asks you" } ?? "unavailable — asks you"
            DebugLog.shared.log(bot: name, colorHex: colorHex, kind: .status, context: "guardrails",
                                text: "reviewer \(verdict): \(request.tool)" + (review.map { " — \($0.reason)" } ?? ""))
        }
        return review
    }

    /// The fast tier with a short timeout: a slow review would stall the bot more than a prompt does.
    private func reviewerBackend() async -> (backend: any ModelBackend, model: String) {
        await fastTier(remoteTimeout: 20, localTimeout: 30)
    }
}
