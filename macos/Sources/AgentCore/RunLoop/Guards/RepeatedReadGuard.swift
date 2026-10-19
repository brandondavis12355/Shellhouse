import Foundation

/// A file the bot already read in full, whose result is still in the prompt, is not read again: the second copy only
/// fills the context sooner, which brings the next summary sooner, which makes the bot read it again. The refusal says
/// where the content is and how to ask for one part. After a summary or a collapse the result is gone from the prompt,
/// so a fresh read is allowed.
public final class RepeatedReadGuard: Guard {
    public let id = "repeated_read"
    public init() {}

    /// A result shorter than this is a stub or an error, not the file.
    static let minimumLength = 200

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard call.name == "read_file", Reliability.isOn(.loopGuards), let path = call.arguments["path"]?.asString,
              Self.fullReadIsInContext(path: path, ctx.messages) else { return [] }
        return [.replaceResult(runJSONString(["error": "You already read all of \(path) and its content is above in this conversation. "
            + "Look there instead of reading it again. If you need one part, use search_files for it, or call read_file with "
            + "offset and limit for those lines (the result above is in your context, so a ranged read adds little). "
            + "Then act on what you know."]), kind: "repeated_read")]
    }

    /// A `read_file` result for `path` that was the whole file (no `next_offset`) and has not been condensed.
    static func fullReadIsInContext(path: String, _ messages: [ChatMessage]) -> Bool {
        let key = "\"path\":\"\(path)\""
        let alternate = key.replacingOccurrences(of: "/", with: "\\/")
        return messages.contains { message in
            message.role == .tool && message.toolName == "read_file" && message.content.count >= minimumLength
                && (message.content.contains(key) || message.content.contains(alternate))
                && !message.content.contains("\"next_offset\"")
        }
    }
}
