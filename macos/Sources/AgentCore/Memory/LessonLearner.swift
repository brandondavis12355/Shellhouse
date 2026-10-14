import Foundation

/// What one run did, kept short, for `LessonLearner`: each tool call and whether it worked.
public final class LessonTrail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var calls = 0
    private var failures = 0
    private var recovered = false
    /// Bookkeeping, not work: nothing to learn from these.
    private static let ignored: Set<String> = [
        "finish_task", "update_user", "get_goal", "propose_goal", "add_goal_step", "edit_goal_step", "update_goal_step",
        "propose_goal_complete", "remember", "recall_memory", "get_profile", "list_routines", "post_to_group",
    ]

    public init() {}

    public func started(_ tool: String, argumentsJSON: String) {
        guard !Self.ignored.contains(tool) else { return }
        lock.lock(); defer { lock.unlock() }
        calls += 1
        lines.append("→ \(tool) \(argumentsJSON.prefix(300))")
    }

    public func completed(_ tool: String, resultJSON: String) {
        guard !Self.ignored.contains(tool) else { return }
        let object = (resultJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let failed = FailureCheck.kind(object) != .ok
        lock.lock(); defer { lock.unlock() }
        if failed { failures += 1 } else if failures > 0 { recovered = true }
        lines.append("← \(failed ? "FAILED" : "ok"): \(resultJSON.prefix(400))")
    }

    /// A failure that was then worked around is where lessons come from; a long run sometimes too.
    public var worthReviewing: Bool { lock.lock(); defer { lock.unlock() }; return recovered || calls >= 12 }

    public var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(lines.joined(separator: "\n").suffix(6_000))
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        lines = []; calls = 0; failures = 0; recovered = false
    }
}

/// After a run that recovered from a failure (or a long one): did the bot learn something reusable that its
/// skills and notes don't already cover? If so, one line goes into its memory.
public enum LessonLearner {
    public static func messages(task: String, trail: String, skills: [(name: String, description: String)], notes: [String]) -> [ChatMessage] {
        let skillList = skills.isEmpty ? "(none)" : skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let noteList = notes.isEmpty ? "(none)" : notes.map { "- \($0)" }.joined(separator: "\n")
        return [
            ChatMessage(role: .system, content: "You pick out reusable lessons for an AI agent's long-term memory. You are strict: most runs teach nothing new."),
            ChatMessage(role: .user, content: """
                The agent's task: \(task.prefix(600))

                What it did, oldest first (→ call, ← result):
                \(trail)

                Playbooks (skills) it already has:
                \(skillList)

                Notes it already keeps:
                \(noteList)

                Did this run teach something that will matter again and that the playbooks and notes above don't already \
                cover? Good lessons: a fix that worked after something failed, a quirk of this machine, repository or tool, \
                a command or setting that turned out to be needed, a preference the user showed. Not lessons: facts that only \
                matter for this one task, general programming knowledge, anything already covered above.

                If yes, reply with ONE line under 200 characters, written as a rule for next time ("When …, …"). Never include \
                passwords, tokens, keys, or personal data. If nothing new was learned, reply exactly NONE.
                """),
        ]
    }

    /// The lesson line from the model's reply, or nil for NONE, junk, or anything that looks like a secret.
    public static func lesson(from reply: String) -> String? {
        var text = reply
        if let end = text.range(of: "</think>", options: .backwards) { text = String(text[end.upperBound...]) }
        guard var line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*•\"'` "))
        guard !line.uppercased().hasPrefix("NONE"), line.count >= 15, line.count <= 300 else { return nil }
        let secretLike = [#"gh[pousr]_[A-Za-z0-9]{20,}"#, #"\bsk-[A-Za-z0-9]{16,}"#, #"[A-Za-z0-9+/=_-]{40,}"#,
                          #"(?i)\b(password|passwd|secret|api[_ ]?key|token)\s*[:=]"#, #"://[^/\s]+:[^@\s]+@"#]
        guard !secretLike.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        return line
    }
}
