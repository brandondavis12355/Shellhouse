import Foundation

/// The same thing again and again. Four checks, all on one idea:
/// - the same call twice in one reply runs once;
/// - the same call (by `repeatFingerprint`) a second and third time gets a nudge, a fourth ends the run;
/// - the same result five times in a row ends the run (a nudge at three);
/// - two actions ping-ponging (`StuckDetector`).
/// A result identical to one still in the prompt is replaced by a short note.
public final class RepeatedCallsGuard: Guard {
    public let id = "repeated_calls"
    public static let repeatThreshold = 3
    public static let sameResultNudgeAt = 3
    public static let sameResultAbortAt = 5
    static let identicalResultMinLength = 400

    private let stale: StaleResultsGuard?
    private var fingerprints: [String: Int] = [:]
    private var seenThisReply = Set<String>()
    private var lastRepeatCount = 0
    private var stuck = StuckDetector()
    private var lastResultKey = ""
    private var sameResultStreak = 0

    /// `stale` is read for "was that result already seen": a call that only repeated a seen result changed nothing.
    public init(stale: StaleResultsGuard? = nil) { self.stale = stale }

    public func reset(_ scope: GuardReset) {
        switch scope {
        case .conversation: stuck = StuckDetector(); fingerprints = [:]
        case .turn: fingerprints = [:]; sameResultStreak = 0
        case .run: break
        }
    }

    public func afterReply(_ reply: ModelReply, cutOff: Bool, _ ctx: RunContext) -> [GuardAction] {
        seenThisReply = []
        return []
    }

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        let key = AgentRuntime.repeatFingerprint(for: call)
        // The same call twice in one assistant turn runs once; the second still gets an answer.
        if Reliability.isOn(.callChecks), !seenThisReply.insert(key).inserted {
            return [.replaceResult(runJSONString(["note": "Duplicate of an identical call in this same turn; it was run once, see the result above."]),
                                   kind: "duplicate_call")]
        }
        // A read whose earlier result has since been collapsed out of the context is not a repeat: the model no
        // longer has that text, so asking again is the right move.
        if AgentRuntime.parallelReadTools.contains(call.name), fingerprints[key] != nil,
           let path = call.arguments["path"]?.asString,
           !ctx.messages.contains(where: { $0.role == .tool && $0.toolName == call.name && !$0.content.hasPrefix("[earlier output") && $0.content.contains(path) }) {
            fingerprints[key] = 0
        }
        let count = (fingerprints[key] ?? 0) + 1
        fingerprints[key] = count
        lastRepeatCount = count
        if count > Self.repeatThreshold { return [.abort("repeated the same '\(call.name)' call too many times")] }
        return []
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed(let isObservation) = outcome.kind else { return [] }
        var actions: [GuardAction] = []
        // The same look at the same thing, with the same answer, while the first answer is still in the conversation:
        // say so instead of pasting it again (it doubled the context and sent bots round in circles).
        let resultText = runJSONString(outcome.shown)
        if Reliability.isOn(.loopGuards), isObservation, resultText.count > Self.identicalResultMinLength,
           ctx.messages.suffix(40).contains(where: { $0.role == .tool && $0.toolName == call.name && $0.content == resultText }) {
            actions.append(.replaceResult(runJSONString(["unchanged": true, "note":
                "Identical to your earlier \(call.name) result with the same arguments, which is still above in this conversation. "
                + "Nothing changed. Use what you already have and take the next step; don't read it again."]), kind: "unchanged_result"))
        }
        // Something changed on the machine (an install, a write, a command with side effects): checking again
        // is now a different question, so earlier identical checks no longer count as a loop. Unless it printed
        // exactly what it printed before (`git checkout` of the branch you're on): then nothing changed.
        if !isObservation, !(stale?.lastWasSeen ?? false) {
            fingerprints.removeAll()
            lastResultKey = ""
            sameResultStreak = 0
            stuck.reset()
        }
        // A tool returning the very same result again and again means the model is going in circles.
        let resultKey = call.name + "|" + runJSONString(outcome.raw)
        if resultKey == lastResultKey { sameResultStreak += 1 } else { lastResultKey = resultKey; sameResultStreak = 1 }
        if Reliability.isOn(.loopGuards) {
            if sameResultStreak == Self.sameResultNudgeAt {
                actions.append(.nudge(Nudge(kind: "same_result", text:
                    "\(call.name) has now returned the identical result \(sameResultStreak) times in a row. Running it again, even "
                    + "reworded, will not change the answer. An empty or negative result is information: change your approach "
                    + "(for example, a package lookup that prints nothing usually means the package lists are not loaded: run "
                    + "`sudo apt-get update` first), do what the result implies, or say plainly that you are blocked and what you need.",
                    escalation: .specific)))
            } else if sameResultStreak >= Self.sameResultAbortAt {
                actions.append(.abort("'\(call.name)' kept returning the same result; the run was going in circles"))
            }
        }
        // Escalating nudges before the hard stop at `repeatThreshold`, which would otherwise end the run with no
        // chance to course-correct. A soft one at the second identical call; the last allowed repeat gets a much more
        // insistent one: an empty or negative result IS the answer, not a reason to check again.
        if lastRepeatCount == 2 {
            actions.append(.nudge(Nudge(kind: "repeat_call", text:
                "You just called \(call.name) again with the exact same arguments — you already "
                + "have that result above, calling it again won't produce a different answer. If "
                + "you're trying to verify something, act on what you already learned now instead of "
                + "re-checking; repeating this same call much more will end the run early with no result.")))
        } else if lastRepeatCount == Self.repeatThreshold {
            actions.append(.nudge(Nudge(kind: "repeat_call_last", text:
                "This is the SAME '\(call.name)' call for the \(lastRepeatCount)rd time in a row, "
                + "with no different action taken in between — ONE more repeat of it will end this "
                + "run early with nothing accomplished. If you were checking whether something exists "
                + "and the result says it doesn't, that IS your answer — take whatever action follows "
                + "from that now (e.g. create it) instead of checking a fourth time.", escalation: .specific)))
        }
        switch Reliability.isOn(.loopGuards) ? stuck.recordAction(AgentRuntime.repeatFingerprint(for: call)) : .fine {
        case .abort(let why): actions.append(.abort(why))
        case .nudge(let text): actions.append(.nudge(Nudge(kind: "alternating", text: text, escalation: .specific)))
        case .fine: break
        }
        return actions
    }
}
