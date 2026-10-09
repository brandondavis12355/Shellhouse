import AgentCore
import SwiftUI
import AppKit

/// Renders `text` word-wrapped like plain body text, except any `@Name`
/// span matching a known bot (by `mentionColors`, keyed on the lowercased
/// full name) becomes a colored capsule pill instead of plain text. Shared
/// between `TranscriptView` (1:1 chat — other bots you could delegate to)
/// and `GroupChatTranscriptView` (group members). Matching is greedy-
/// longest-first over consecutive words after the `@` (capped at
/// `maxMentionWords`), so a multi-word bot name like "Dr. EggBot" pills up
/// as one unit instead of just its first word — see `rawSegments`, also
/// shared with `GroupChatSession.mentionedMemberIDs` so the pill and the
/// actual "who gets called to respond" logic can never disagree about
/// what counts as a mention.
struct MentionPillText: View {
    let text: String
    let mentionColors: [String: String]
    var fontSize: CGFloat = NSFont.systemFontSize + 4

    /// Whether `text` contains any recognized mention at all — callers use
    /// this to decide between this view (word-level, no markdown
    /// highlighting) and a richer text renderer for the common case of a
    /// message with no mentions in it.
    static func containsKnownMention(_ text: String, mentionColors: [String: String]) -> Bool {
        !MentionScanner.matchedNames(in: text, knownNames: Set(mentionColors.keys)).isEmpty
    }

    /// The set of known names (or the literal "everyone") actually mentioned in `text`.
    static func matchedNames(in text: String, knownNames: Set<String>) -> Set<String> {
        MentionScanner.matchedNames(in: text, knownNames: knownNames)
    }

    /// One concatenated `AttributedString`, not a row of separate `Text`
    /// views in a flow layout (the previous approach) — sibling `Text`
    /// views each own their own selection context on macOS, so a
    /// click-drag (or Cmd+A/copy) inside the old layout only ever grabbed
    /// whichever single word/pill the drag started on, never the whole
    /// message. One `Text` backed by one `AttributedString` is a single
    /// selection context, so drag-select and copy span the entire message
    /// again — the mention "pill" is now a background-color run instead
    /// of an actual `Capsule` shape (per-run shapes aren't something
    /// `AttributedString` can express), but it still reads as visually
    /// distinct, colored and bold.
    private var attributedText: AttributedString {
        let segments = MentionScanner.segments(for: text, knownNames: Set(mentionColors.keys))
        var result = AttributedString()
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .word(let sep, let word):
                if index > 0 { result += AttributedString(sep.isEmpty ? " " : sep) }
                var run = AttributedString(word)
                run.font = .system(size: fontSize)
                result += run
            case .mention(let sep, let display, let name):
                if index > 0 { result += AttributedString(sep.isEmpty ? " " : sep) }
                var run = AttributedString(display)
                run.font = .system(size: fontSize, weight: .semibold)
                let color = name == "everyone" ? Color.gray : (mentionColors[name].map { Color(hex: $0) } ?? .primary)
                run.foregroundColor = color
                run.backgroundColor = color.opacity(0.22)
                result += run
            }
        }
        return result
    }

    var body: some View {
        Text(attributedText)
    }
}
