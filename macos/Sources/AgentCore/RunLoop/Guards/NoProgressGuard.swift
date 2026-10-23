import Foundation

/// Steps that add nothing, of whatever kind, in a row: an announcement instead of a call, a read of something the
/// bot has already seen, a call that was refused or answered with "duplicate", a plan rewrite. Each of the other loop
/// guards counts one kind and waits for its own threshold, so a bot mixing kinds (two narrations, a repeated read, a
/// refused call, another narration) trips none of them and goes many steps before doing anything. Here they add up.
///
/// A step counts as progress when it changes something (a call that is not just looking) or shows a result the bot has
/// not seen before in this conversation. Desktop tools are left to the desktop guards: a screenshot's JSON looks the
/// same every time though the screen differs. Nudges at 3 steps, and more firmly at 6. It never stops the run by itself.
public final class NoProgressGuard: Guard {
    public let id = "no_progress"
    public static let nudgeAt = 3
    public static let insistAt = 6

    private var streak = 0
    private var informative = false
    private var seen = Set<String>()

    public init() {}

    public func reset(_ scope: GuardReset) {
        switch scope {
        case .conversation: streak = 0; seen = []; informative = false
        case .turn: streak = 0; informative = false
        case .run: break
        }
    }

    public func afterReply(_ reply: ModelReply, cutOff: Bool, _ ctx: RunContext) -> [GuardAction] {
        informative = false
        // A reply with no call is a step that did nothing; the runtime does not run `afterTurn` for it.
        guard (reply.message.toolCalls ?? []).isEmpty else { return [] }
        return step(informative: false)
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed(let isObservation) = outcome.kind else { return [] }
        if !isObservation || Self.leftToDesktopGuards.contains(call.name) { informative = true; return [] }
        let key = StaleResultsGuard.key(call, observation: outcome.raw) ?? call.name + "|" + runJSONString(outcome.raw)
        if seen.insert(key).inserted { informative = true }
        return []
    }

    public func afterTurn(ranTools: Bool, _ ctx: RunContext) -> [GuardAction] {
        step(informative: informative)
    }

    private static let leftToDesktopGuards = DesktopCycleGuard.actions.union(["screenshot", "list_windows"])

    private func step(informative: Bool) -> [GuardAction] {
        guard Reliability.isOn(.loopGuards) else { return [] }
        guard !informative else { streak = 0; return [] }
        streak += 1
        if streak == Self.nudgeAt {
            return [.nudge(Nudge(kind: "no_progress", text: "[no progress] Your last \(streak) steps added nothing new: no change was made and nothing "
                + "you hadn't already seen came back. Say in one line what you know now, then take the ONE action that changes something "
                + "or tells you something new. If there is none, call finish_task with outcome \"blocked\" and say what you need.", escalation: .specific))]
        }
        if streak == Self.insistAt {
            return [.nudge(Nudge(kind: "no_progress_insist", text: "[no progress] \(streak) steps in a row with nothing new. Stop exploring and stop describing: "
                + "either make the change the task needs right now, or call finish_task with outcome \"blocked\" and report what you found and what is missing.",
                escalation: .restrictTools))]
        }
        return []
    }
}
