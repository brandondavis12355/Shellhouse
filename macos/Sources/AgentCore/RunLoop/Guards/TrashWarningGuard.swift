import Foundation

/// A command that deletes through a path the user may want back gets a warning in its result.
public final class TrashWarningGuard: Guard {
    public let id = "trash_warning"
    public init() {}

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind, Reliability.isOn(.failureHints), outcome.shown["warning"] == nil,
              let trash = ObservationPolicy.trashWarning(forArguments: runJSONString(call.arguments.mapValues(\.value)))
        else { return [] }
        return [.annotate(key: "warning", value: trash)]
    }
}
