import Foundation

/// A group chat as a readable Markdown document: a header (group, members, when exported), then each
/// message with its time and speaker. App notices are set off in italics. Tool evidence is left out: it's
/// the bots' working output, not the conversation.
public enum GroupTranscriptExport {
    public struct Line: Sendable {
        public enum Kind: Sendable { case user, bot, friend, notice }
        public let time: Date
        public let speaker: String
        public let text: String
        public let kind: Kind
        public init(time: Date, speaker: String, text: String, kind: Kind) {
            self.time = time; self.speaker = speaker; self.text = text; self.kind = kind
        }
    }

    public static func markdown(groupName: String, members: [String], lines: [Line], exportedAt: Date = Date(),
                                timeZone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(groupName)\n\n"
        if !members.isEmpty { out += "Members: \(members.joined(separator: ", "))  \n" }
        out += "Exported \(stamp.string(from: exportedAt)) · \(lines.count) message\(lines.count == 1 ? "" : "s")\n\n---\n"
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch line.kind {
            case .notice:
                out += "\n*\(stamp.string(from: line.time)) · \(text.replacingOccurrences(of: "\n", with: " "))*\n"
            case .user, .bot, .friend:
                let tag = line.kind == .friend ? " (friend)" : line.kind == .bot ? " (bot)" : ""
                out += "\n**\(line.speaker)**\(tag) · \(stamp.string(from: line.time))\n\n\(text)\n"
            }
        }
        return out
    }

    /// A safe file name: "Shellhouse Working Session" -> "Shellhouse-Working-Session-transcript-2026-10-13.md".
    public static func fileName(groupName: String, date: Date = Date()) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let base = groupName.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        return "\(base.isEmpty ? "group" : String(base.prefix(60)))-transcript-\(day).md"
    }
}
