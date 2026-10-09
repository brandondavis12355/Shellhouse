import Foundation

/// Reads the one-word answer to "should you reply?" from a small model. Models wrap answers in
/// thinking tags, add punctuation or explain themselves; the rule is: only a clear, lone "NO" means
/// stay quiet. Anything unclear means reply, because a missing answer costs more than a surplus one.
public enum ReplyGate {
    public static func shouldReply(from raw: String) -> Bool {
        var text = raw
        // Drop reasoning blocks some models emit before the answer.
        while let open = text.range(of: "<think>", options: .caseInsensitive),
              let close = text.range(of: "</think>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let open = text.range(of: "<think>", options: .caseInsensitive) { text.removeSubrange(open.lowerBound..<text.endIndex) }
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`\"'#>-:[]()"))).uppercased()
        guard !upper.isEmpty else { return true }

        let hasYes = upper.range(of: #"\bYES\b"#, options: .regularExpression) != nil
        let hasNo = upper.range(of: #"\bNO\b"#, options: .regularExpression) != nil
        if hasYes { return true }      // "NO, wait: YES" or any hedging toward yes
        guard hasNo else { return true }

        // A lone NO (optionally with punctuation / a short trailing note) is a refusal.
        let first = upper.prefix { $0.isLetter }
        let wordCount = upper.split(whereSeparator: { !$0.isLetter }).count
        return !(first == "NO" && wordCount <= 6)
    }
}
