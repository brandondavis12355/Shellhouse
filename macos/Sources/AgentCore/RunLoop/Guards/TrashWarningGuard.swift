import Foundation

/// A command that deletes through a path the user may want back gets a warning in its result.
public final class TrashWarningGuard: Guard {
    public let id = "trash_warning"
    public init() {}

    /// The arguments as JSON with slashes left alone: `JSONSerialization` writes them as `\/`, which hid every trash path.
    static func argumentsText(_ call: ToolCall) -> String {
        let data = try? JSONSerialization.data(withJSONObject: call.arguments.mapValues(\.value), options: [.sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard case .executed = outcome.kind, Reliability.isOn(.failureHints), outcome.shown["warning"] == nil,
              let trash = ObservationPolicy.trashWarning(forArguments: Self.argumentsText(call))
        else { return [] }
        return [.annotate(key: "warning", value: trash)]
    }
}
