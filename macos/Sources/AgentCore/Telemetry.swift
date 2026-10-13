import Foundation

/// Who a model call or tool run belongs to. Set with `Telemetry.$context.withValue(...)` around a run or a
/// fast-model call; child tasks inherit it, so calls deep inside a run are attributed without plumbing.
public struct TelemetryContext: Sendable {
    public var bot: String
    public var purpose: String
    public init(bot: String, purpose: String) { self.bot = bot; self.purpose = purpose }
}

public enum Telemetry {
    @TaskLocal public static var context: TelemetryContext?
    public static let recorder = TelemetryRecorder()

    /// "group: Shellhouse Working Session" -> "group turn", so purposes group into a few kinds.
    public static func kind(of purpose: String) -> String {
        let p = purpose.lowercased()
        if p.hasPrefix("group") || p.hasPrefix("goal") { return "group turn" }
        if p.hasPrefix("delegated") { return "delegation" }
        if p.hasPrefix("routine") { return "routine" }
        return purpose
    }
}

/// Everything the Telemetry window shows, since app launch. In memory only; thread-safe.
public final class TelemetryRecorder: @unchecked Sendable {
    public struct ModelCall: Sendable {
        public let time: Date
        public let bot: String
        public let purpose: String
        public let model: String
        public let promptTokens: Int
        public let completionTokens: Int
        public let seconds: Double
        /// Server-measured generation time (Ollama), for an honest tokens/second.
        public let generationSeconds: Double?
        public let loadSeconds: Double?
        public let error: String?
    }

    public struct Event: Sendable, Identifiable {
        public let id = UUID()
        public let time: Date
        public let bot: String
        public let kind: String
        public let text: String
    }

    public struct Totals: Sendable {
        public var calls = 0, failedCalls = 0
        public var promptTokens = 0, completionTokens = 0
        public var seconds = 0.0, generationSeconds = 0.0, loadSeconds = 0.0
        /// Completion tokens from calls that reported their generation time, so the speed isn't skewed.
        public var timedCompletionTokens = 0
        public var tokensPerSecond: Double? { generationSeconds > 0 ? Double(timedCompletionTokens) / generationSeconds : nil }
        public init() {}
        mutating func add(_ call: ModelCall) {
            calls += 1
            if call.error != nil { failedCalls += 1 }
            promptTokens += call.promptTokens
            completionTokens += call.completionTokens
            seconds += call.seconds
            if let generation = call.generationSeconds, generation > 0 {
                generationSeconds += generation
                timedCompletionTokens += call.completionTokens
            }
            loadSeconds += call.loadSeconds ?? 0
        }
    }

    public struct BotStats: Sendable {
        public var model = Totals()
        public var toolRuns = 0, toolFailures = 0
        public var runs = 0, runsStopped = 0, compactions = 0
        public var lastPromptTokens = 0
        public var lastActivity: Date?
        public var lastModel = ""
        public init() {}
    }

    public struct ToolStats: Sendable {
        public var runs = 0, failures = 0, seconds = 0.0
    }

    public struct Snapshot: Sendable {
        public let startedAt: Date
        public let total: Totals
        public let byBot: [String: BotStats]
        public let byPurpose: [String: Totals]
        public let byModel: [String: Totals]
        public let tools: [String: ToolStats]
        public let approvals: [String: Int]
        public let stopReasons: [String: Int]
        public let recent: [Event]
    }

    private let lock = NSLock()
    private let startedAt = Date()
    private var total = Totals()
    private var byBot: [String: BotStats] = [:]
    private var byPurpose: [String: Totals] = [:]
    private var byModel: [String: Totals] = [:]
    private var tools: [String: ToolStats] = [:]
    private var approvals: [String: Int] = [:]
    private var stopReasons: [String: Int] = [:]
    private var recent: [Event] = []
    static let recentLimit = 300

    public init() {}

    private func note(_ bot: String, _ kind: String, _ text: String) {
        recent.append(Event(time: Date(), bot: bot, kind: kind, text: text))
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    public func modelCall(model: String, promptTokens: Int, completionTokens: Int, seconds: Double,
                          generationSeconds: Double? = nil, loadSeconds: Double? = nil, error: String? = nil) {
        let context = Telemetry.context
        let bot = context?.bot ?? "app"
        let purpose = Telemetry.kind(of: context?.purpose ?? "other")
        let call = ModelCall(time: Date(), bot: bot, purpose: purpose, model: model, promptTokens: promptTokens,
                             completionTokens: completionTokens, seconds: seconds, generationSeconds: generationSeconds,
                             loadSeconds: loadSeconds, error: error)
        lock.lock(); defer { lock.unlock() }
        total.add(call)
        byPurpose[purpose, default: Totals()].add(call)
        byModel[model, default: Totals()].add(call)
        var stats = byBot[bot, default: BotStats()]
        stats.model.add(call)
        if promptTokens > 0 { stats.lastPromptTokens = promptTokens }
        stats.lastActivity = call.time
        stats.lastModel = model
        byBot[bot] = stats
        let speed = generationSeconds.flatMap { $0 > 0 ? String(format: ", %.0f tok/s", Double(completionTokens) / $0) : nil } ?? ""
        note(bot, error == nil ? "model" : "model error",
             "\(purpose) · \(model) · \(promptTokens) in / \(completionTokens) out · \(String(format: "%.1f", seconds)) s\(speed)"
                + (error.map { " · \($0.prefix(120))" } ?? ""))
    }

    public func toolRun(_ tool: String, seconds: Double, failed: Bool) {
        let bot = Telemetry.context?.bot ?? "app"
        lock.lock(); defer { lock.unlock() }
        var stats = tools[tool, default: ToolStats()]
        stats.runs += 1; stats.seconds += seconds
        if failed { stats.failures += 1 }
        tools[tool] = stats
        byBot[bot, default: BotStats()].toolRuns += 1
        if failed { byBot[bot, default: BotStats()].toolFailures += 1 }
        byBot[bot, default: BotStats()].lastActivity = Date()
        note(bot, failed ? "tool failed" : "tool", "\(tool) · \(String(format: "%.1f", seconds)) s")
    }

    /// A guardrail outcome: auto, reviewer_auto, approved, denied_by_user, denied, ...
    public func approval(_ tool: String, outcome: String) {
        let bot = Telemetry.context?.bot ?? "app"
        lock.lock(); defer { lock.unlock() }
        approvals[outcome, default: 0] += 1
        if outcome != "auto" { note(bot, "guardrail", "\(tool) · \(outcome)") }
    }

    public func runEnded(stoppedBecause reason: String?) {
        let bot = Telemetry.context?.bot ?? "app"
        let purpose = Telemetry.kind(of: Telemetry.context?.purpose ?? "other")
        lock.lock(); defer { lock.unlock() }
        byBot[bot, default: BotStats()].runs += 1
        if let reason {
            byBot[bot, default: BotStats()].runsStopped += 1
            let key = reason.replacingOccurrences(of: "[0-9]+", with: "N", options: .regularExpression)
            stopReasons[String(key.prefix(80)), default: 0] += 1
        }
        note(bot, reason == nil ? "run" : "run stopped", "\(purpose)" + (reason.map { " · \($0.prefix(140))" } ?? " · finished"))
    }

    public func compaction(dropped: Int) {
        let bot = Telemetry.context?.bot ?? "app"
        lock.lock(); defer { lock.unlock() }
        byBot[bot, default: BotStats()].compactions += 1
        note(bot, "compaction", "summarized \(dropped) earlier messages")
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(startedAt: startedAt, total: total, byBot: byBot, byPurpose: byPurpose, byModel: byModel,
                        tools: tools, approvals: approvals, stopReasons: stopReasons, recent: recent)
    }
}
