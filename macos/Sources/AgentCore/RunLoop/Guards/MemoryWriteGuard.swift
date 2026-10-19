import Foundation

/// The gate in front of every tool that saves a note. A saved note is read again on later runs, so a run that has read
/// untrusted content (`ToolGate` taint) may not leave instructions behind for a future run, and no note may be large.
/// This is one layer: whatever gets through is still stored as `untrusted` (`MemoryTrust`) and held for review by `ToolGate`.
public final class MemoryWriteGuard: Guard {
    public let id = "memory_write_gate"
    public init() {}

    /// Tools that write notes. A new note tool belongs here, or it bypasses the gate.
    public static let noteTools: Set<String> = ["remember", "replace_memory", "remember_task", "save_evidence"]
    public static let maxCharacters = 300

    /// Phrases that address a future run rather than record a fact. Heuristic, deliberately broad for a tainted run.
    static let phrases = [
        "ignore previous", "ignore all", "ignore the above", "ignore your", "disregard", "forget your", "forget all",
        "from now on", "new instructions", "system prompt", "you must", "you should", "you are now", "do not tell",
        "don't tell", "without asking", "without telling", "do not ask", "don't ask", "no need to ask", "no need to confirm",
        "always ", "never ", "whenever ", "every time", "next time", "in future", "in the future", "pipe to sh", "| sh", "| bash",
    ]
    /// A note that starts with an imperative aimed at the reader.
    static let leadingVerbs = ["run ", "execute ", "send ", "post ", "email ", "upload ", "download ", "install ", "delete ", "remove ",
                               "forward ", "reveal ", "share ", "include ", "append ", "use ", "call ", "fetch ", "open ", "ask ", "tell "]

    public static func looksLikeInstruction(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return phrases.contains { t.contains($0) } || leadingVerbs.contains { t.hasPrefix($0) }
    }

    /// The text a call would save: its `text`, or every string argument for a tool this doesn't know.
    static func text(of call: ToolCall) -> String {
        if let text = call.arguments["text"]?.asString { return text }
        return call.arguments.values.compactMap(\.asString).joined(separator: " ")
    }

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard Self.noteTools.contains(call.name) else { return [] }
        let text = Self.text(of: call)
        if text.count > Self.maxCharacters {
            return [.replaceResult(runJSONString(["error": "Not saved: that note is \(text.count) characters. Keep a note to one or two sentences, "
                + "under \(Self.maxCharacters) characters: the fact or rule you will need again, not the content you read."]),
                kind: "memory_write_too_long")]
        }
        if !ctx.taintSources.isEmpty, Self.looksLikeInstruction(text) {
            return [.replaceResult(runJSONString(["error": "Not saved: this run has read untrusted content (\(ctx.taintSources.joined(separator: ", "))), "
                + "and a note that tells a future run what to do could have come from it. Record a plain fact instead, or ask the user to add the rule."]),
                kind: "memory_write_blocked")]
        }
        return []
    }
}
