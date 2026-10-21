import Foundation

/// The prompt, as a pure function of the run log. Nothing here mutates the log: collapsing old output, dropping old
/// screenshots, leaving out an announcement and replacing a stretch of history with its summary are all rules applied
/// while reading it. The same log always renders the same messages, and while no rule's input changes, the start of
/// the rendering is byte-identical from one step to the next (the model server can keep reusing its cache of it).
public struct ContextView: Sendable {
    /// Result of rendering: the messages, and which event each came from (a summary carries its own event's id).
    public struct Rendered: Sendable {
        public var messages: [ChatMessage] = []
        public var sourceIDs: [Int] = []
    }

    /// Screenshots kept in the prompt (Anthropic's computer-use reference prunes to the newest few for the same reason).
    public static let maxRetainedImages = 2
    /// Applies `ObservationPolicy.collapseStale` and `dropStaleNarration` with their defaults to the finished rendering.
    public var collapseOldOutput: Bool

    public init(collapseOldOutput: Bool = true) {
        self.collapseOldOutput = collapseOldOutput
    }

    public static let prunedScreenshotText = "(an older screenshot was here; it's been removed to save context — "
        + "take a fresh one if you need to see current state)"

    public static func summaryMessageText(_ summary: String) -> String {
        "(Earlier conversation summarized to keep this within the model's context — "
            + "nothing before this point is verbatim anymore:)\n\n\(summary)"
    }

    public func render(_ events: [RunEvent]) -> Rendered {
        var out = Rendered()
        var superseded = Set<Int>()
        for event in events {
            if case .nudge(_, _, _, let target?, _) = event.kind { superseded.insert(target) }
        }
        for event in events {
            switch event.kind {
            case .system(let text):
                add(ChatMessage(role: .system, content: text), event.id, &out)
            case .userMessage(let content, let images):
                add(ChatMessage(role: .user, content: content, images: (images ?? []).isEmpty ? nil : images), event.id, &out)
            case .modelReply(let message):
                if !superseded.contains(event.id) { add(message, event.id, &out) }
            case .toolResult(let name, let content):
                add(ChatMessage(role: .tool, content: content, toolName: name), event.id, &out)
            case .screenshot(let content, let images):
                add(ChatMessage(role: .user, content: content, images: images), event.id, &out)
                pruneScreenshots(&out)
            case .nudge(_, let text, _, _, let inContext):
                if inContext { add(ChatMessage(role: .user, content: text), event.id, &out) }
            case .condensed(.summary(let first, let last, let text)):
                if let from = out.sourceIDs.firstIndex(of: first), let to = out.sourceIDs.lastIndex(of: last), from <= to {
                    out.messages.replaceSubrange(from...to, with: [ChatMessage(role: .user, content: Self.summaryMessageText(text))])
                    out.sourceIDs.replaceSubrange(from...to, with: [event.id])
                }
            case .condensed(.collapse(let keepLast, let minCharacters, let batch)):
                out.messages = ObservationPolicy.collapseStale(out.messages, keepLast: keepLast, minCharacters: minCharacters, batch: batch)
            case .verification, .approval, .stateNote:
                break
            }
        }
        if collapseOldOutput { out.messages = ObservationPolicy.dropStaleNarration(ObservationPolicy.collapseStale(out.messages)) }
        return out
    }

    private func add(_ message: ChatMessage, _ id: Int, _ out: inout Rendered) {
        out.messages.append(message)
        out.sourceIDs.append(id)
    }

    /// Run when a screenshot arrives, like the in-place pruning it replaces: only screenshot turns trigger it.
    private func pruneScreenshots(_ out: inout Rendered) {
        let withImages = out.messages.indices.filter { !(out.messages[$0].images ?? []).isEmpty }
        guard withImages.count > Self.maxRetainedImages else { return }
        for index in withImages.dropLast(Self.maxRetainedImages) {
            out.messages[index].images = nil
            out.messages[index].content = Self.prunedScreenshotText
        }
    }
}
