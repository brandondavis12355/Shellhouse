import Foundation

/// The same loop every time a bot works the desktop:
///
///  1. The bot reasons about its first action, then looks: a screenshot (with the grid). If it tries to act before looking, the
///     harness takes the screenshot for it and says so (the attempted action is not run).
///  2. The harness asks, "Is there something we should do next, or do we stop?" The bot says what it sees and why, then makes ONE
///     action, aimed from that screenshot, or stops with `finish_task` and the state it is in.
///  3. The action's result carries a new screenshot. The harness asks, "Did the action we took do what we expected? If not, what do
///     we need to do differently?" The bot answers, then makes the next single action or stops.
///
/// Rules that keep it the same each time: one action per reply (the next one waits for the result), every action is preceded by a
/// sentence of reasoning (asked for once, then let through), and three actions in a row that changed nothing end the work: the bot
/// reports where things stand instead of trying a fourth.
public final class DesktopCycleGuard: Guard {
    public let id = "desktop_cycle"
    /// Calls that change what is on the screen. `screenshot`, `page_text` and `find_on_page` only look.
    public static let actions: Set<String> = ["click", "move_mouse", "type_text", "type_secret", "press_key", "scroll", "click_text", "fill_field", "open_app", "focus_window"]
    public static let failureLimit = 3

    private enum Phase { case idle, afterLook, afterAction }
    private var phase = Phase.idle
    private var observed = false
    /// An action the harness replaced with a screenshot because the bot had not looked yet.
    private var replaced: String?
    private var actedThisReply = false
    private var askedForReasoning = false
    private var failures = 0

    public init() {}

    public func reset(_ scope: GuardReset) {
        phase = .idle; observed = false; replaced = nil; actedThisReply = false; askedForReasoning = false; failures = 0
    }

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard Self.actions.contains(call.name), Reliability.isOn(.loopGuards) else { return [] }
        if !observed {
            replaced = call.name
            return [.rewrite(ToolCall(name: "screenshot", arguments: [:]))]
        }
        if actedThisReply {
            return [.replaceResult(runJSONString(["error": "Not run: one action at a time. \(call.name) comes after you have seen what the last action did. "
                + "Make it in your next reply."]), kind: "desktop_one_action")]
        }
        if !askedForReasoning, Self.reasoning(in: ctx).count < 15 {
            askedForReasoning = true
            return [.replaceResult(runJSONString(["error": "Not run: first write one or two sentences, then make the call: what you see on the screen "
                + "(or whether the last action worked), and why this action is the right next one. Then call \(call.name) again."]), kind: "desktop_reason_first")]
        }
        return []
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind else { return [] }
        let failed = outcome.raw["error"] != nil
        if call.name == "screenshot" {
            guard !failed else { return [] }
            observed = true
            phase = .afterLook
            if let was = replaced {
                replaced = nil
                return [.annotate(key: "harness_note", value: "Your \(was) was not run: look at the screen first. This is the screen now. "
                    + "Say what you see, then make the action if it is still right.")]
            }
            return []
        }
        guard Self.actions.contains(call.name) else { return [] }
        actedThisReply = true
        askedForReasoning = false
        phase = .afterAction
        observed = !failed && outcome.raw["screenshot"] != nil
        if call.name == "open_app" { observed = false }
        if failed || outcome.raw["screen_changed"] as? Bool == false { failures += 1 } else { failures = 0 }
        return []
    }

    public func afterTurn(ranTools: Bool, _ ctx: RunContext) -> [GuardAction] {
        defer { actedThisReply = false }
        guard Reliability.isOn(.loopGuards) else { return [] }
        if actedThisReply, phase == .afterAction {
            if failures >= Self.failureLimit {
                return [.nudge(Nudge(kind: "desktop_stop", text: "The last \(failures) actions did not change the screen as expected. Stop trying: call finish_task now with "
                    + "outcome \"blocked\" and tell the user the state we are in: what is on the screen, what was done, what did not work, and what you would try next.", escalation: .specific))]
            }
            return [.nudge(Nudge(kind: "desktop_verify", text: Self.verifyPrompt, escalation: .soft))]
        }
        if phase == .afterLook, observed {
            phase = .idle
            return [.nudge(Nudge(kind: "desktop_decide", text: Self.decidePrompt, escalation: .soft))]
        }
        return []
    }

    public static let decidePrompt = "You have looked at the screen. Is there something we should do next, or do we stop? "
        + "Say what you see and why in one or two sentences. If there is a next step, make that ONE action, aimed from the screenshot (read the grid). "
        + "If we are done, or cannot go on, call finish_task and tell the user the state we are in."

    public static let verifyPrompt = "Compare the new screenshot with what you expected. Did the action we took do what we expected? If not, what do we need to do differently? "
        + "Answer in one or two sentences. Then make the next single action, or, if the work is done or we cannot go on, call finish_task and tell the user the state we are in "
        + "(what is on the screen, what was done, what is left)."

    /// The sentence(s) of reasoning in the reply being acted on.
    private static func reasoning(in ctx: RunContext) -> String {
        (ctx.messages.last { $0.role == .assistant }?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
