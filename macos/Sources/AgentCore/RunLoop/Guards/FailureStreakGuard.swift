import Foundation

/// The user wants to hear about a problem before the bot takes more actions on it: a hard failure, or two in a row,
/// tell it to stop and report; the same failure three times (nothing new is being learned), or six failures of any
/// kind, end the run. A test that fails differently each run is debugging, not a loop. Any success starts over.
public final class FailureStreakGuard: Guard {
    public let id = "failure_streak"
    private var failureStreak = 0
    private var sameFailureStreak = 0
    private var lastFailureKey = ""

    public init() {}

    public func reset(_ scope: GuardReset) {
        if scope == .turn { failureStreak = 0; sameFailureStreak = 0; lastFailureKey = "" }
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard Reliability.isOn(.loopGuards) else { return [] }
        let kind = FailureCheck.kind(outcome.shown)
        guard kind != .ok else { failureStreak = 0; sameFailureStreak = 0; lastFailureKey = ""; return [] }
        let key: String
        switch outcome.kind {
        case .refused: key = call.name + (outcome.shown["error"] as? String ?? "")
        case .executed: key = call.name + FailureCheck.key(outcome.shown)
        }
        failureStreak += 1
        sameFailureStreak = key == lastFailureKey ? sameFailureStreak + 1 : 1
        lastFailureKey = key
        if sameFailureStreak >= FailureCheck.stopAfter || failureStreak >= FailureCheck.stopAfterAny {
            return [.abort(sameFailureStreak >= FailureCheck.stopAfter
                ? "the same action failed \(sameFailureStreak) times in a row, so it stopped to check with you before trying anything else"
                : "\(failureStreak) actions in a row failed, so it stopped to check with you before trying anything else")]
        }
        if kind == .blocked {
            return [.nudge(Nudge(kind: "blocked", text: FailureCheck.blockedNotice, escalation: .specific))]
        }
        if kind == .hard || sameFailureStreak == 2 || failureStreak == FailureCheck.stopAfter {
            return [.nudge(Nudge(kind: "failure_stop", text: FailureCheck.stopNotice, escalation: .specific))]
        }
        return []
    }
}
