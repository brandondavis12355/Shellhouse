import Foundation

/// What one chat message is, for grouping: the chat view maps its own message type onto this.
public enum TranscriptKind: Sendable, Equatable {
    case user
    /// The bot's own text.
    case assistantText
    /// A tool's result.
    case tool
    /// A turn's closing summary (`finish_task`, or a plain reply that ended the turn).
    case summary
    /// A "Messaged <bot>" notice: always its own row.
    case interBot
    /// A stop or error notice: always its own message, never folded away.
    case notice
}

public enum TranscriptRow<ID: Hashable>: Equatable {
    case message(ID)
    /// Everything the bot did on the way to its answer: tool results and the text it wrote between calls.
    case activity([ID])
}

/// Turns a flat list of chat messages into rows, so a request that took twelve tool calls reads as one activity row and
/// the answer, not as twenty bubbles. Within each turn (the stretch after one of your messages), everything up to and
/// including the last tool result is activity; what comes after it is the answer and stays a normal message. A turn with
/// no tool call is untouched. Display only: the messages themselves, the saved transcript and the model's context are
/// not changed by this.
public enum ActivityGrouping {
    ///
    /// Narration is folded in too: only the turn's last text (the answer) stays a message, plus notices and notes to other
    /// bots. While `live`, the newest turn has no answer yet, so all of its text is activity until the run ends.
    public static func rows<ID: Hashable>(_ items: [(id: ID, kind: TranscriptKind)], live: Bool = false) -> [TranscriptRow<ID>] {
        var rows: [TranscriptRow<ID>] = []
        var turnStart = 0
        func flush(upTo end: Int) {
            let isNewest = end == items.count
            guard turnStart < end else { return }
            let turn = Array(items[turnStart..<end])
            guard let lastTool = turn.lastIndex(where: { $0.kind == .tool }) else {
                rows.append(contentsOf: turn.map { .message($0.id) }); return
            }
            var group: [ID] = []
            func closeGroup() { if !group.isEmpty { rows.append(.activity(group)); group = [] } }
            let isText: (TranscriptKind) -> Bool = { $0 == .assistantText || $0 == .summary }
            // A `.summary` is collapsed to "Done" because it repeats a reply, so the reply is the answer; the summary only
            // counts when no plain text follows the last tool.
            let answer = (live && isNewest) ? nil
                : turn.indices.last { $0 > lastTool && turn[$0].kind == .assistantText } ?? turn.indices.last { $0 > lastTool && turn[$0].kind == .summary }
            let foldedUpTo = answer ?? (live && isNewest ? turn.count : lastTool + 1)
            for (offset, item) in turn.enumerated() {
                let inActivity = offset < foldedUpTo && (item.kind == .tool || isText(item.kind))
                if inActivity { group.append(item.id) } else { closeGroup(); rows.append(.message(item.id)) }
            }
            closeGroup()
        }
        for (index, item) in items.enumerated() where item.kind == .user {
            flush(upTo: index)
            rows.append(.message(item.id))
            turnStart = index + 1
        }
        flush(upTo: items.count)
        return rows
    }
}
