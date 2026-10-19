import Foundation

/// How hard a guard is pushing. Declared by the guard, recorded on every firing, so a change to a rule shows up
/// as numbers rather than as a feeling. `restrictTools` is reserved for the capability profiles (docs/HARNESS-REDESIGN.md 3.6).
public enum Escalation: Int, Codable, Sendable, Comparable {
    case soft, specific, restrictTools, stop
    public static func < (a: Escalation, b: Escalation) -> Bool { a.rawValue < b.rawValue }
}

/// A correction shown to the model as the next user turn.
public struct Nudge: Sendable, Equatable {
    /// Also the name of the telemetry counter (`Telemetry.loopEvent`).
    public var kind: String
    public var text: String
    public var escalation: Escalation
    /// Skip it when the last thing the model was shown is this very text.
    public var skipIfRepeat: Bool

    public init(kind: String, text: String, escalation: Escalation = .soft, skipIfRepeat: Bool = false) {
        self.kind = kind
        self.text = text
        self.escalation = escalation
        self.skipIfRepeat = skipIfRepeat
    }
}

/// What a guard asks the runtime to do. The runtime does it and writes the event; guards never touch the log.
public enum GuardAction {
    case none
    case nudge(Nudge)
    /// Leave the reply just made out of the prompt (an announcement the model would copy). The chat already showed it.
    case dropReply
    /// Show the reply in the chat without its text (it repeats an earlier announcement).
    case hideReplyText
    /// Replace the call (`beforeTool`, `afterReply`: the reply becomes this call).
    case rewrite(ToolCall)
    /// Answer the call (or the finish attempt) with this tool-result JSON instead of running it. `kind` names the counter.
    case replaceResult(String, kind: String)
    /// Add a field to the result the model will read.
    case annotate(key: String, value: String)
    /// Make the prompt smaller now (the runtime summarizes or stubs old output).
    case condense(threshold: Int, estimatedTokens: Int)
    /// A plain-text reply is the answer: end the turn with it.
    case endTurn(String)
    /// Stop the run with this reason.
    case abort(String)
}

/// What a guard may look at. A snapshot taken by the runtime just before the hook runs.
public struct RunContext {
    public var iteration = 0
    public var maxIterations = 0
    public var goal = ""
    public var plan: [AgentRuntime.PlanItem] = []
    public var toolNames: Set<String> = []
    /// The registry's tools, and the same plus `finish_task` (what a call is checked against).
    public var registrySchemas: [ToolSchema] = []
    public var validationSchemas: [ToolSchema] = []
    /// The prompt as the model will see it.
    public var messages: [ChatMessage] = []
    public var toolCallsThisTurn = 0
    public var compactionThresholdTokens = 0
    public var contextWindow = 32_768
    public var schemaTokens = 0
    public var lastPromptTokens = 0
    public var lastCompactionMessageCount: Int?
    /// Why the run counts as tainted (`TaintSource` names); empty while it has read nothing untrusted.
    public var taintSources: [String] = []
    /// This run's log id, and the id of the model reply being acted on (what a saved note points back to).
    public var session = ""
    public var replyEventID = 0

    public init() {}

    public var openPlanItems: [AgentRuntime.PlanItem] { plan.filter { $0.status == .pending || $0.status == .in_progress } }
}

/// One tool call's result, as the guards see it.
public struct ToolOutcome {
    public enum Kind: Equatable {
        /// The tool ran. `isObservation`: it only looked.
        case executed(isObservation: Bool)
        /// The gate refused it; `shown` carries the error.
        case refused
    }
    public var kind: Kind
    /// What the tool returned.
    public var raw: [String: Any]
    /// What the model will read: bounded, annotated.
    public var shown: [String: Any]

    public init(kind: Kind, raw: [String: Any], shown: [String: Any]) {
        self.kind = kind
        self.raw = raw
        self.shown = shown
    }
}

/// The model asked to end the task.
public struct FinishRequest {
    public var summary: String
    public var outcome: String
    /// How many calls the reply made (a refusal answers the call, so only a lone finish can be refused).
    public var callCount: Int
}

/// Which saved state a reset clears. `start` applies all three; `send` the turn; `seed` the conversation.
public enum GuardReset {
    /// A new or restored conversation (`start`, `seed`).
    case conversation
    /// A new user message (`start`, `send`).
    case turn
    /// A brand-new run (`start`).
    case run
}

/// One rule of the loop, with its own state. Every hook has a no-op default; a guard implements the ones it needs.
/// Guards run in a fixed order (`GuardSet.standard`); the first `abort` wins.
public protocol Guard: AnyObject {
    var id: String { get }
    func reset(_ scope: GuardReset)
    /// Before the model is called.
    func beforeModel(_ ctx: RunContext) -> [GuardAction]
    /// The model replied (before the reply is recorded). `cutOff`: the reply was cut for repeating itself.
    func afterReply(_ reply: ModelReply, cutOff: Bool, _ ctx: RunContext) -> [GuardAction]
    /// Before a call runs (it may be rewritten, answered, or end the run).
    func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction]
    /// A call has a result (it was refused, or ran). Annotations apply before the result is recorded.
    func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction]
    /// All the calls of one reply are done. `ranTools`: at least one actually executed.
    func afterTurn(ranTools: Bool, _ ctx: RunContext) -> [GuardAction]
    /// The model called `finish_task`. A `replaceResult` or `nudge` refuses it.
    func beforeFinish(_ request: FinishRequest, _ ctx: RunContext) -> [GuardAction]
}

public extension Guard {
    func reset(_ scope: GuardReset) {}
    func beforeModel(_ ctx: RunContext) -> [GuardAction] { [] }
    func afterReply(_ reply: ModelReply, cutOff: Bool, _ ctx: RunContext) -> [GuardAction] { [] }
    func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] { [] }
    func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] { [] }
    func afterTurn(ranTools: Bool, _ ctx: RunContext) -> [GuardAction] { [] }
    func beforeFinish(_ request: FinishRequest, _ ctx: RunContext) -> [GuardAction] { [] }
}

/// Sorted-key JSON for a tool result, the one encoding the model, the log and the guards all use.
func runJSONString(_ dict: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
        return "{\"error\":\"failed to encode tool result\"}"
    }
    return String(data: data, encoding: .utf8) ?? "{}"
}

public extension AgentRuntime.PlanItem {
    /// The plan as the model and the reminder show it.
    static func text(of plan: [AgentRuntime.PlanItem]) -> String {
        plan.map { item in
            let mark: String
            switch item.status {
            case .done: mark = "[x]"
            case .in_progress: mark = "[~]"
            case .blocked: mark = "[!]"
            case .pending: mark = "[ ]"
            }
            return "\(mark) \(item.text)"
        }.joined(separator: "\n")
    }
}
