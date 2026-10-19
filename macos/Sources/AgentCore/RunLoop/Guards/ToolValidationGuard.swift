import Foundation

/// A call that cannot work gets a precise correction (missing field, wrong type, "did you mean run_shell?", a shell
/// syntax error) instead of a confusing failure or an approval prompt. An unknown tool is never run.
public final class ToolValidationGuard: Guard {
    public let id = "tool_validation"
    public init() {}

    public func beforeTool(_ call: ToolCall, _ ctx: RunContext) -> [GuardAction] {
        guard ctx.toolNames.contains(call.name) else {
            let message = Reliability.isOn(.callChecks)
                ? (ToolCallValidator.problem(with: call, schemas: ctx.validationSchemas) ?? "unknown tool '\(call.name)'")
                : "unknown tool '\(call.name)'"
            return [.replaceResult(runJSONString(["error": message]), kind: "unknown_tool")]
        }
        guard Reliability.isOn(.callChecks) else { return [] }
        if let problem = ToolCallValidator.problem(with: call, schemas: ctx.validationSchemas) {
            return [.replaceResult(runJSONString(["error": problem]), kind: "invalid_call")]
        }
        if call.name == "run_shell", let command = call.arguments["command"]?.asString, let problem = ShellLint.problem(in: command) {
            return [.replaceResult(runJSONString(["error": problem]), kind: "shell_lint")]
        }
        return []
    }
}
