import Foundation

/// A reasoning model's thinking, kept out of what people read.
///
/// Two kinds leak. Tagged thinking (`<think>…</think>`, or only the closing tag when the chat template already
/// opened it) is removed outright. Untagged self-talk (a model talking itself round in a loop, "Actually, wait,
/// let me re-read the instructions…") can't be cut out of a reply, so it is recognised and the reply is left
/// out: better a missing reply than the model's inner monologue in the chat.
public enum ReasoningText {
    private static let open = "<think>"
    private static let close = "</think>"

    /// `text` without tagged thinking, trimmed. For a finished message.
    public static func strip(_ text: String) -> String {
        visible(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` without tagged thinking, for one still arriving: an open block is hidden as it streams, and a
    /// half-arrived tag is left alone until it completes.
    public static func visible(_ text: String) -> String {
        guard text.range(of: open, options: .caseInsensitive) != nil
                || text.range(of: close, options: .caseInsensitive) != nil else { return text }
        var out = text
        // Whole blocks.
        while let start = out.range(of: open, options: .caseInsensitive),
              let end = out.range(of: close, options: .caseInsensitive, range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // A closing tag with no opener: the template opened it, so everything before it was thinking.
        if let end = out.range(of: close, options: [.caseInsensitive, .backwards]) {
            out = String(out[end.upperBound...])
        }
        // A block still open: everything after its opener.
        if let start = out.range(of: open, options: .caseInsensitive) {
            out.removeSubrange(start.lowerBound..<out.endIndex)
        }
        return out
    }

    /// Phrases a model uses when it is deliberating with itself rather than addressing anyone.
    private static let selfTalk = [
        "actually, wait", "wait, actually", "wait —", "wait -", "hmm,", "let me re-read", "let me reread",
        "let me think about this", "let me just stop", "stop looping", "stop this loop", "no more looping",
        "but actually,", "actually, looking more carefully", "actually, i realize", "actually, let me",
        "re-read the instructions", "i should just report", "let me just report",
    ]

    /// Whether `text` reads as the model's own deliberation: several self-talk phrases, or the same paragraph
    /// said over and over. Ordinary replies, even long ones, do neither.
    public static func looksLikeDeliberation(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.count >= 200 else { return false }   // short text can't be a loop
        var hits = 0
        for phrase in selfTalk where lower.contains(phrase) {
            hits += 1
            if hits >= 3 { return true }
        }
        // Counting every occurrence matters: a loop repeats one phrase, it doesn't use many.
        if hits >= 1 {
            for phrase in selfTalk {
                var seen = 0, from = lower.startIndex
                while let r = lower.range(of: phrase, range: from..<lower.endIndex) {
                    seen += 1
                    if seen >= 3 { return true }
                    from = r.upperBound
                }
            }
        }
        return repeatsParagraphs(lower)
    }

    /// The same paragraph (or sentence-length line) at least twice.
    private static func repeatsParagraphs(_ lower: String) -> Bool {
        var counts: [String: Int] = [:]
        for chunk in lower.components(separatedBy: "\n") {
            let line = chunk.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard line.count >= 60 else { continue }
            counts[line, default: 0] += 1
            if counts[line]! >= 2 { return true }
        }
        return false
    }
}
