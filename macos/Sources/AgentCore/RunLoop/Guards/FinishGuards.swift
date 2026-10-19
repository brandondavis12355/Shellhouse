import Foundation

/// `finish_task` needs something to report.
public final class EmptySummaryGuard: Guard {
    public let id = "empty_summary"
    public init() {}

    // `summary` is `required` in the schema, but some models hand back tool calls that skip required fields anyway:
    // completing with nothing would silently end the whole task with no result at all.
    public func beforeFinish(_ request: FinishRequest, _ ctx: RunContext) -> [GuardAction] {
        guard request.summary.isEmpty else { return [] }
        return [.nudge(Nudge(kind: "empty_summary", text: "finish_task needs a non-empty `summary` — the actual result, or a clear "
            + "explanation of why you're blocked. Call it again with that filled in.", escalation: .specific))]
    }
}

/// "Done" with plan steps still open: refuse once (Roo Code's completion guard), so "done" means done.
/// Only when finish_task is the sole call, so every call in the turn still gets an answer. A second attempt goes through.
public final class OpenPlanGuard: Guard {
    public let id = "open_plan"
    private var used = false
    public init() {}

    public func reset(_ scope: GuardReset) {
        if scope == .turn { used = false }
    }

    public func beforeFinish(_ request: FinishRequest, _ ctx: RunContext) -> [GuardAction] {
        let open = ctx.openPlanItems
        guard request.outcome == "done", request.callCount == 1, !open.isEmpty, !used else { return [] }
        used = true
        return [.replaceResult(runJSONString(["error": "Not finished: your plan still has open steps:\n"
            + open.map { "- \($0.text) (\($0.status.rawValue))" }.joined(separator: "\n")
            + "\nDo them, or call update_plan marking each done or blocked (with the reason), then finish."]), kind: "open_plan")]
    }
}

/// "Done" right after changing code, with nothing run since: ask for the check once. A write to code or config sets
/// it; any shell command, screenshot or job check clears it. Prose files don't count.
public final class UnverifiedChangeGuard: Guard {
    public let id = "unverified_change"
    static let docExtensions: Set<String> = ["md", "txt", "rst", "csv", "log"]
    private var unverified = false
    private var used = false
    public init() {}

    public func reset(_ scope: GuardReset) {
        if scope == .turn { unverified = false; used = false }
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind else { return [] }
        switch call.name {
        case "write_file", "edit_file":
            guard outcome.raw["error"] == nil, let path = call.arguments["path"]?.asString else { return [] }
            if !Self.docExtensions.contains((path as NSString).pathExtension.lowercased()) { unverified = true }
        case "run_shell", "screenshot", "check_job":
            unverified = false
        default:
            break
        }
        return []
    }

    public func beforeFinish(_ request: FinishRequest, _ ctx: RunContext) -> [GuardAction] {
        guard request.outcome == "done", request.callCount == 1, unverified, !used, Reliability.isOn(.taskFocus) else { return [] }
        used = true
        return [.replaceResult(runJSONString(["error": "Not finished: you changed files and ran nothing afterwards to check them. Run the test, command or request that "
            + "shows it works (or take a screenshot), read the output, fix what it shows, then call finish_task with that output "
            + "as evidence. If nothing can be run, say so in the summary."]), kind: "unverified_done")]
    }
}
