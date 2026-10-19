import Foundation

/// A model that writes its tool call as text (or sends arguments of the wrong type) still gets its call made:
/// the text is read back as the call it meant, and string-typed numbers and booleans are coerced to the schema.
public final class ToolCallRecoveryGuard: Guard {
    public let id = "tool_call_recovery"
    public init() {}

    public func afterReply(_ reply: ModelReply, cutOff: Bool, _ ctx: RunContext) -> [GuardAction] {
        guard Reliability.isOn(.callChecks), !cutOff, (reply.message.toolCalls ?? []).isEmpty,
              let recovered = ToolCallRecovery.extract(from: reply.message.content, toolNames: ctx.toolNames, schemas: ctx.registrySchemas)
        else { return [] }
        return [.rewrite(recovered)]
    }

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard Reliability.isOn(.callChecks) else { return [] }
        return [.rewrite(ToolCallValidator.coerced(call, schemas: ctx.registrySchemas))]
    }
}
