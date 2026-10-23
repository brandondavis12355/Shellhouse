import Foundation

/// Whether a bot's model reasons before it answers. Per bot (Settings → Model).
public enum ThinkingMode: String, Codable, Sendable, CaseIterable {
    /// Never: fastest. The default, and what the app always did.
    case off
    /// Every step.
    case on
    /// Where it pays: the first step of a task (the plan) and the steps right after something went wrong. Routine tool
    /// steps run without it. Hidden reasoning is the main cost of a local model step (a greeting took ~99 s with it on and
    /// ~1.2 s off, docs/MODEL_TIERS.md), and a step that only follows an obvious next move gains little from it.
    case auto

    public var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .auto: return "Auto"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "No hidden reasoning: fastest."
        case .on: return "Reason before every step: slower, often more careful."
        case .auto: return "Reason on the first step of a task and after something goes wrong; skip it on routine steps."
        }
    }
}

/// What a single model call should do about thinking, set by the runtime around the call. A backend that supports it
/// (Ollama's `think`) reads it; the rest ignore it. Task-local so it reaches the call through the scheduler and fallback
/// wrappers without changing the `ModelBackend` protocol.
public enum ModelThinking {
    @TaskLocal public static var override: Bool?

    /// Temperature for a step that reasons. Greedy-like settings make reasoning models repeat themselves; the model
    /// cards of the Qwen3 family recommend about 0.6 for thinking mode (not verified for every model).
    public static let thinkingTemperature = 0.6
}

/// Decides, per step, whether to think. Pure, so it is tested without a model.
public struct ThinkingPolicy: Sendable, Equatable {
    public var mode: ThinkingMode
    /// The first model call of a task (`start` or `send`).
    public var firstStepOfTask = false
    /// A guard fired since the last model call, of a kind that means the bot is in trouble (see `troubleKinds`).
    public var troubleSinceLastStep = false

    public init(mode: ThinkingMode, firstStepOfTask: Bool = false, troubleSinceLastStep: Bool = false) {
        self.mode = mode
        self.firstStepOfTask = firstStepOfTask
        self.troubleSinceLastStep = troubleSinceLastStep
    }

    public var shouldThink: Bool {
        switch mode {
        case .off: return false
        case .on: return true
        case .auto: return firstStepOfTask || troubleSinceLastStep
        }
    }

    /// Guard firings after which the next step is worth reasoning about: loops, repeated errors, nothing new coming
    /// back, a refused finish. Routine reminders and budget notes are not.
    public static let troubleKinds: Set<String> = [
        "narration", "narration_escalated", "missing_tool", "monologue", "calls_not_run", "repetition_cut",
        "repeat_call", "repeat_call_last", "same_result", "alternating", "same_error", "failure_stop", "blocked",
        "stale_results", "no_progress", "no_progress_insist", "repeated_read", "unverified_done", "open_plan",
        "desktop_stop", "invalid_call", "unknown_tool", "shell_lint",
    ]
}
