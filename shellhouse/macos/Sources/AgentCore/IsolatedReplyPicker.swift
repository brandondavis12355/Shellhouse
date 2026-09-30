import Foundation

/// Decides which text an isolated run (group turn, delegation, routine
/// into a group) actually posts. A run can produce several candidates —
/// plain-text turns the model wrote, and `finish_task`'s `summary` — and
/// models disagree about which one holds the real answer: some narrate
/// ("I'll post it now") and put the real message in `summary`; others
/// write the real message as plain text and then give a terse recap as
/// `summary`. Neither field is reliably right, but the wrong one is
/// reliably the SHORTER: narration and recaps are brief, deliverables are
/// not. So the longest candidate wins, ties going to `summary` (the
/// documented contract). Intermediate text that accompanied a non-finish
/// tool call is excluded — that is working narration, never a deliverable.
public struct IsolatedReplyPicker: Sendable {
    private var plainCandidates: [String] = []
    private var summary: String?

    public init() {}

    public mutating func observe(_ message: ChatMessage) {
        guard message.role == .assistant else { return }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if message.isTaskSummary {
            summary = text
            return
        }
        let calls = message.toolCalls ?? []
        let isPlainTurn = calls.isEmpty || calls.contains { $0.name == "finish_task" }
        if isPlainTurn { plainCandidates.append(text) }
    }

    public var result: String? {
        var best = summary
        for candidate in plainCandidates where candidate.count > (best?.count ?? 0) {
            best = candidate
        }
        return best
    }
}
