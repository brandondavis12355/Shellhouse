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

    private static let trimChars = CharacterSet(charactersIn: ".,!?:;()\"'")
    private static let maxMentionWords = 5

    private enum Segment {
        case word(String)
        /// `display` keeps the original words/punctuation as typed
        /// (e.g. "@Dr. EggBot,"); `name` is the trimmed, lowercased match
        /// key used to look up a color or compare against known names.
        case mention(display: String, name: String)
    }

    /// Whether `text` contains any recognized mention at all — callers use
    /// this to decide between this view (word-level, no markdown
    /// highlighting) and a richer text renderer for the common case of a
    /// message with no mentions in it.
    static func containsKnownMention(_ text: String, mentionColors: [String: String]) -> Bool {
        rawSegments(for: text, knownNames: Set(mentionColors.keys)).contains {
            if case .mention = $0 { return true }
            return false
        }
    }

    /// The set of known names (from `knownNames`, or the literal
    /// "everyone") actually mentioned in `text` — what
    /// `GroupChatSession.mentionedMemberIDs` calls to decide who should
    /// respond to a turn.
    static func matchedNames(in text: String, knownNames: Set<String>) -> Set<String> {
        Set(rawSegments(for: text, knownNames: knownNames).compactMap {
            if case .mention(_, let name) = $0 { return name }
            return nil
        })
    }

    /// Core tokenizer: walks `text` word by word, and at each `@`-prefixed
    /// word tries the longest run of subsequent words first, falling back
    /// to shorter runs, before giving up and treating it as plain text.
    /// "everyone" always counts as a match regardless of `knownNames`, so
    /// group-chat callers don't have to inject it themselves.
    private static func rawSegments(for text: String, knownNames: Set<String>) -> [Segment] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var result: [Segment] = []
        var i = 0
        while i < words.count {
            guard words[i].hasPrefix("@") else {
                result.append(.word(words[i]))
                i += 1
                continue
            }
            var matchedLength: Int?
            let upperBound = min(maxMentionWords, words.count - i)
            for length in stride(from: upperBound, through: 1, by: -1) {
                let phrase = words[i..<(i + length)].joined(separator: " ")
                let name = phrase.dropFirst().trimmingCharacters(in: trimChars).lowercased()
                guard !name.isEmpty else { continue }
                if name == "everyone" || knownNames.contains(name) {
                    result.append(.mention(display: phrase, name: name))
                    matchedLength = length
                    break
                }
            }
            if let matchedLength {
                i += matchedLength
            } else {
                result.append(.word(words[i]))
                i += 1
            }
        }
        return result
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
        let segments = Self.rawSegments(for: text, knownNames: Set(mentionColors.keys))
        var result = AttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { result += AttributedString(" ") }
            switch segment {
            case .word(let word):
                var run = AttributedString(word)
                run.font = .system(size: fontSize)
                result += run
            case .mention(let display, let name):
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
