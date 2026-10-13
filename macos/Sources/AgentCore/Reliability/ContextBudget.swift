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
        WHAT WORKED: exact commands or steps that succeeded and will be needed again.
        DECISIONS: choices made and by whom.
        OPEN: what is still in progress, blocked, or waiting on someone, and what's next.
        Quote exact values (paths, versions, IDs, error text) rather than paraphrasing them. Never include \
        passwords, tokens or keys. This replaces the history above, so leave out nothing still needed.
        """
}
