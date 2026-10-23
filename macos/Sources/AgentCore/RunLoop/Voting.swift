import Foundation

/// Majority vote over a few samples of the same question. A small model answers a short yes/no question
/// inconsistently at any temperature above 0, and at 0 it is consistently wrong in the same way, so the vote keeps the
/// greedy answer as one voter and adds a few sampled ones (self-consistency, cheap here because the fast model is small
/// and the question is one word long).
public enum GateVote {
    public static let samplesKey = "reliability.gateVotes"
    public static let defaultSamples = 3
    /// Sampled voters' temperature. Voter 0 always runs at 0.
    public static let temperature = 0.7

    /// How many samples per decision: 1 turns voting off. Even numbers round up, so there is never an exact tie.
    public static func samples(defaults: UserDefaults = .standard) -> Int {
        let raw = defaults.object(forKey: samplesKey) == nil ? defaultSamples : defaults.integer(forKey: samplesKey)
        let clamped = min(7, max(1, raw))
        return clamped % 2 == 0 ? clamped + 1 : clamped
    }

    public struct Result: Equatable, Sendable {
        public var answer: Bool?
        public var yes = 0, no = 0, failed = 0
        public var unanimous: Bool { answer != nil && (yes == 0 || no == 0) }
    }

    /// `nil` answer when nobody answered or the vote is tied (only possible when some voters failed): the caller then
    /// falls back to its single-call path.
    public static func tally(_ answers: [Bool?]) -> Result {
        var result = Result()
        for answer in answers {
            switch answer {
            case true?: result.yes += 1
            case false?: result.no += 1
            case nil: result.failed += 1
            }
        }
        result.answer = result.yes == result.no ? nil : result.yes > result.no
        return result
    }

    /// Asks `count` voters at once. `ask(index, temperature)`: voter 0 gets 0, the rest `temperature`.
    public static func decide(count: Int, ask: @escaping @Sendable (_ voter: Int, _ temperature: Double) async -> Bool?) async -> Result {
        let answers = await withTaskGroup(of: (Int, Bool?).self) { group -> [Bool?] in
            for voter in 0..<max(1, count) {
                group.addTask { (voter, await ask(voter, voter == 0 ? 0 : temperature)) }
            }
            var collected = [Bool?](repeating: nil, count: max(1, count))
            for await (voter, answer) in group { collected[voter] = answer }
            return collected
        }
        let result = tally(answers)
        Telemetry.recorder.loopEvent(result.answer == nil ? "gate_vote_failed" : (result.unanimous ? "gate_vote_unanimous" : "gate_vote_split"))
        return result
    }
}

/// Which of several sampled replies to act on: the one whose first action most of them agree on. Used only on the step
/// after the no-progress guard fires, when the first sample is the one that has been going nowhere.
public enum ActionVote {
    public static let samplesKey = "reliability.actionVotes"
    /// 1 (the default) is off: it costs extra model calls on exactly the steps that are already stuck, so it is opt-in
    /// until the consistency suite shows it helps.
    public static func samples(defaults: UserDefaults = .standard) -> Int {
        let raw = defaults.object(forKey: samplesKey) == nil ? 1 : defaults.integer(forKey: samplesKey)
        let clamped = min(7, max(1, raw))
        return clamped % 2 == 0 ? clamped + 1 : clamped
    }

    /// What a reply does, for comparing: its first call (normalized as for repeat detection), a finish with its
    /// outcome, or "text" for a reply with no call.
    static func key(_ reply: ModelReply) -> String {
        guard let call = reply.message.toolCalls?.first else { return "text" }
        if call.name == "finish_task" { return "finish|" + (call.arguments["outcome"]?.asString ?? "done") }
        return AgentRuntime.repeatFingerprint(for: call)
    }

    /// Index of the reply to use. A strict majority wins; otherwise the first (the one already streamed to the chat).
    public static func pick(_ replies: [ModelReply]) -> Int {
        var counts: [String: Int] = [:]
        for reply in replies { counts[key(reply), default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value * 2 > replies.count else { return 0 }
        return replies.firstIndex { key($0) == best.key } ?? 0
    }
}
