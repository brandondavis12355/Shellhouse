import Foundation

/// The third identical error from one tool this turn gets a single message naming it (OpenHands), before the other
/// loop guards would stop the run.
public final class SameErrorGuard: Guard {
    public let id = "same_error"
    public static let nudgeAt = 3
    private var counts: [String: Int] = [:]

    public init() {}

    public func reset(_ scope: GuardReset) {
        if scope == .turn { counts = [:] }
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind, Reliability.isOn(.loopGuards) else { return [] }
        var error = outcome.raw["error"] as? String ?? ""
        if error.isEmpty, let code = outcome.raw["exit_code"] as? Int, code != 0 {
            error = (outcome.raw["stderr"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !error.isEmpty else { return [] }
        let normalized = String(error.prefix(300)).replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        let key = call.name + "|" + normalized
        counts[key, default: 0] += 1
        guard counts[key] == Self.nudgeAt else { return [] }
        return [.nudge(Nudge(kind: "same_error", text:
            "[stuck] \(call.name) has failed \(Self.nudgeAt) times with the same error: \"\(String(error.prefix(240)))\". "
            + "Repeating it won't help. Read the error, check your assumptions (path, name, arguments, whether a tool is installed), "
            + "and try a different approach; if you can't, finish_task with outcome \"blocked\" and say what you need.",
            escalation: .specific))]
    }
}
