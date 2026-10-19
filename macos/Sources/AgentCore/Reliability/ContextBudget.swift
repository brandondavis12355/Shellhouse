import Foundation

/// How much of the model's context window a run may fill before older history is summarized.
public enum ContextBudget {
    /// Room kept free for the model's reply.
    static let replyReserve = 2_048

    /// About 65% of what's left after the tool definitions and the reply, so a long tool result
    /// arriving on the next step still fits. Never below 4,000.
    public static func compactionThreshold(window: Int, schemaTokens: Int) -> Int {
        let usable = window - schemaTokens - replyReserve
        return max(4_000, Int(Double(usable) * 0.65))
    }

    /// The threshold, raised when the fixed start of the conversation (system prompt, goal, skills) already takes
    /// most of it: otherwise every step is over the line and the bot spends its time summarizing itself and
    /// forgetting what it just read. Leaves at least `headroom` tokens of working history, capped at 85% of the window.
    public static func threshold(window: Int, schemaTokens: Int, fixedPrefixTokens: Int, headroom: Int = 6_000) -> Int {
        let base = compactionThreshold(window: window, schemaTokens: schemaTokens)
        let cap = Int(Double(window - schemaTokens - replyReserve) * 0.85)
        return max(base, min(fixedPrefixTokens + headroom, cap))
    }

    /// The rough ~4-characters-per-token estimate (there is no client-side tokenizer for an arbitrary backend). Images
    /// get their own flat estimate: a screenshot is thousands of real tokens, far more than its base64 length suggests.
    public static func estimatedTokens(for message: ChatMessage) -> Int {
        var characters = message.content.utf8.count
        for call in message.toolCalls ?? [] {
            characters += call.name.count + runJSONString(call.arguments.mapValues(\.value)).count
        }
        return characters / 4 + (message.images?.count ?? 0) * 1_100
    }

    /// Tool definitions travel with every request and count against the window.
    public static func estimatedTokens(ofSchemas schemas: [ToolSchema]) -> Int {
        schemas.reduce(0) { total, schema in
            let parameters = (try? JSONSerialization.data(withJSONObject: schema.parameters, options: [.sortedKeys]))?.count ?? 0
            return total + (schema.name.utf8.count + schema.description.utf8.count + parameters) / 4
        }
    }

    /// What the summary must keep, so the bot can carry on without the detailed history.
    public static let summaryInstruction = """
        Summarize the conversation above so you can continue the task without it. Use these headings, \
        keep each to the facts, and skip any that are empty:
        GOAL: what you are trying to achieve, in one line.
        DONE AND VERIFIED: what was completed and how it was confirmed (command and result).
        FILES AND PATHS: files, directories, branches, URLs and names you created or rely on.
        KEY FINDINGS: for each file or page you read, the facts you need from it (function names, line numbers, \
        exact values, what is wrong), so you never have to read it again.
        WHAT WORKED: exact commands or steps that succeeded and will be needed again.
        DECISIONS: choices made and by whom.
        OPEN: what is still in progress, blocked, or waiting on someone, and what's next. Never list reading a file \
        you have already read as a next step: use KEY FINDINGS, and name only what you still do not know.
        Quote exact values (paths, versions, IDs, error text) rather than paraphrasing them. Never include \
        passwords, tokens or keys. Later tool results override earlier claims: drop anything a later result \
        contradicts, and don't list as done or decided what no tool result or message confirmed. This replaces \
        the history above, so leave out nothing still needed.
        """

    /// The summary text without a reasoning model's thinking (everything up to a closing `</think>`).
    public static func cleanSummary(_ text: String) -> String {
        var out = text
        if let end = out.range(of: "</think>", options: .backwards) { out = String(out[end.upperBound...]) }
        out = out.replacingOccurrences(of: #"<think>[\s\S]*"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tool results one bot has already seen, kept for a while across its runs (see `AgentRuntime.staleStreak`).
public final class SeenResults: @unchecked Sendable {
    private var seen: [String: Date] = [:]
    private let lock = NSLock()
    private let lifetime: TimeInterval
    public init(lifetime: TimeInterval = 15 * 60) { self.lifetime = lifetime }

    /// Records `key`; whether it had already been seen within the lifetime.
    public func saw(_ key: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { now.timeIntervalSince($0.value) < lifetime }
        let before = seen[key] != nil
        seen[key] = now
        return before
    }
}
