import Foundation

/// Reports paths a tool result says do not exist, so a note that names one can be flagged "possibly stale". It never
/// changes the call, the result or the prompt; it only tells the app. Silent in a tainted run: untrusted content
/// must not be able to flag a trusted note.
public final class MissingPathGuard: Guard {
    public let id = "missing_path_hint"
    private let onMissing: @Sendable (String) -> Void
    public init(onMissing: @escaping @Sendable (String) -> Void) { self.onMissing = onMissing }

    private static let missing = try? NSRegularExpression(pattern: #"(/[^\s:'"]+): No such file or directory"#)

    static func missingPaths(call: ToolCall, outcome: ToolOutcome) -> [String] {
        guard case .executed = outcome.kind else { return [] }
        let text = runJSONString(outcome.raw).replacingOccurrences(of: "\\/", with: "/")
        var found: [String] = []
        if let regex = missing {
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { found.append(String(text[r])) }
            }
        }
        if call.name == "read_file", let path = call.arguments["path"]?.asString, path.contains("/"),
           let error = (outcome.raw["error"] as? String)?.lowercased(),
           error.contains("no such file") || error.contains("not found") || error.contains("does not exist") {
            found.append(path)
        }
        return Array(Set(found)).sorted()
    }

    public func afterTool(_ call: ToolCall, _ outcome: ToolOutcome, _ ctx: RunContext) -> [GuardAction] {
        guard ctx.taintSources.isEmpty else { return [] }
        for path in Self.missingPaths(call: call, outcome: outcome) { onMissing(path) }
        return []
    }
}
