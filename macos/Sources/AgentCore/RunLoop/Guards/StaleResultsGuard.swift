import Foundation

/// Results this bot already saw, in this run or a recent one (`SeenResults` is shared across its runs). A run getting
/// back nothing but already-seen results is waiting or polling, whatever the commands look like, and side effects
/// (a `git fetch`, a checkout) don't reset it the way they reset the other loop guards.
public final class StaleResultsGuard: Guard {
    public let id = "stale_results"
    public static let nudgeAt = 4
    public static let abortAt = 7

    private let seen: SeenResults
    private var streak = 0
    /// Whether the last result was one already seen: `RepeatedCallsGuard` doesn't treat that as a change in the world.
    public private(set) var lastWasSeen = false

    public init(seen: SeenResults = SeenResults()) { self.seen = seen }

    public func reset(_ scope: GuardReset) {
        if scope == .conversation { streak = 0 }
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        lastWasSeen = false
        guard case .executed = outcome.kind, Reliability.isOn(.loopGuards), let key = Self.key(call, observation: outcome.raw) else { return [] }
        lastWasSeen = seen.saw(key)
        streak = lastWasSeen ? streak + 1 : 0
        if streak == Self.nudgeAt {
            return [.nudge(Nudge(kind: "stale_results", text:
                "Your last \(streak) results were all ones you had already seen (this turn or an earlier one): "
                + "nothing has changed. Checking again won't change it. If you're waiting on someone (a push, a review, a "
                + "decision), say in one line what you're waiting for and end your turn now; you'll be woken when they post. "
                + "If you're the one who should act, act on what you already know.", escalation: .specific))]
        }
        if streak >= Self.abortAt {
            return [.abort("nothing new came back for \(streak) calls in a row: it was waiting, not working")]
        }
        return []
    }

    /// What a result says: shell output without echo labels or checkout chatter. `nil` for tiny or write-type
    /// results, which neither count nor reset the streak.
    static func key(_ call: ToolCall, observation: [String: Any]) -> String? {
        if ["update_user", "post_to_group", "message_bot", "write_file", "edit_file", "remember", "finish_task"].contains(call.name) { return nil }
        let text: String
        if call.name == "run_shell" {
            let raw = ["stdout", "stderr", "error"].compactMap { observation[$0] as? String }.joined(separator: "\n")
            text = raw.split(separator: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !(t.hasPrefix("---") || t.hasPrefix("===") || t.hasPrefix("Already on ") || t.hasPrefix("Switched to branch "))
            }.joined(separator: "\n")
        } else {
            text = runJSONString(observation)
        }
        guard text.count >= 40 else { return nil }
        return call.name + "|" + text
    }
}
