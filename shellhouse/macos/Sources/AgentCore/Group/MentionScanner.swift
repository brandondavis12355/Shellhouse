import Foundation

/// Finds `@Name` mentions in a message. The one place that decides what counts as a mention, shared by
/// the transcript's pill rendering and by the group's "who gets called to respond" logic, so the two
/// can never disagree.
public enum MentionScanner {
    public enum Segment: Equatable, Sendable {
        /// `sep` is the whitespace that originally preceded the word (a space, or a line break), kept so
        /// rebuilding the text never flattens paragraphs.
        case word(sep: String, text: String)
        /// `display` keeps the words/punctuation as typed ("@Dr. EggBot,"); `name` is the trimmed,
        /// lowercased key used to look up a color or compare with known names.
        case mention(sep: String, display: String, name: String)
    }

    private static let trimChars = CharacterSet(charactersIn: ".,!?:;()\"'")
    public static let maxMentionWords = 5

    private struct Token { let sep: String; let word: String }

    /// Splits on ANY whitespace (a mention at the start of a new line or paragraph counts) and remembers
    /// the separators. An opening bracket or quote glued to an `@` ("(@Cleo") is treated as separator.
    private static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var sep = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            var w = word
            var s = sep
            while let first = w.first, "([\"“‘".contains(first), w.dropFirst().first == "@" {
                s.append(first)
                w.removeFirst()
            }
            out.append(Token(sep: s, word: w))
            sep = ""
            word = ""
        }
        for ch in text {
            if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
                flush()
                sep.append(ch)
            } else {
                word.append(ch)
            }
        }
        flush()
        return out
    }

    /// Walks `text` word by word; at each `@` word tries the longest run of following words first (so a
    /// multi-word name like "Dr. EggBot" is one mention), never across a line break. "everyone" always
    /// matches.
    public static func segments(for text: String, knownNames: Set<String>) -> [Segment] {
        let words = tokens(text)
        var result: [Segment] = []
        var i = 0
        while i < words.count {
            guard words[i].word.hasPrefix("@") else {
                result.append(.word(sep: words[i].sep, text: words[i].word))
                i += 1
                continue
            }
            var matchedLength: Int?
            var reach = 1
            while reach < min(maxMentionWords, words.count - i), words[i + reach].sep == " " { reach += 1 }
            for length in stride(from: reach, through: 1, by: -1) {
                let phrase = words[i..<(i + length)].map(\.word).joined(separator: " ")
                let name = phrase.dropFirst().trimmingCharacters(in: trimChars).lowercased()
                guard !name.isEmpty else { continue }
                if name == "everyone" || knownNames.contains(name) {
                    result.append(.mention(sep: words[i].sep, display: phrase, name: name))
                    matchedLength = length
                    break
                }
            }
            if let matchedLength {
                i += matchedLength
            } else {
                result.append(.word(sep: words[i].sep, text: words[i].word))
                i += 1
            }
        }
        return result
    }

    public static func matchedNames(in text: String, knownNames: Set<String>) -> Set<String> {
        Set(segments(for: text, knownNames: knownNames).compactMap {
            if case .mention(_, _, let name) = $0 { return name }
            return nil
        })
    }
}
